import Darwin
import Foundation
import GRPCCore

/// CLI shutdown.
///  - power-key: ask Android itself to shut down by sending the power button
///    over gRPC `sendKey` (allowed with `aud`); the user then taps "Power off".
///  - terminate: one SIGTERM to the verified Emulator process, then wait.
///    Never SIGKILL, never a second signal, never deleting locks.
enum Shutdown {
    enum PowerMode: String, Sendable, CaseIterable {
        /// Short press: usually screen off/on.
        case short
        /// Hold 1.5 s: power menu, or the assistant on some Pixel images.
        case long
        /// Power + Volume Up held 1.5 s: the Pixel power-menu chord.
        case chord
    }

    /// Linux evdev codes.
    static let keyPower: Int32 = 116, keyVolumeUp: Int32 = 115
    static let holdMS = 1500

    /// Ordered key steps: (code, down) with an optional hold before the first up.
    static func steps(_ mode: PowerMode) -> [(code: Int32, down: Bool)] {
        switch mode {
        case .short, .long: return [(keyPower, true), (keyPower, false)]
        case .chord: return [(keyVolumeUp, true), (keyPower, true), (keyPower, false), (keyVolumeUp, false)]
        }
    }
    static func holds(_ mode: PowerMode) -> Bool { mode != .short }

    // MARK: power-key

    struct PowerReport: Encodable, Sendable {
        var operation = "power-key"
        var mode = ""
        var instanceVerified = false
        var keyCreated = false
        var keyLoaded = false
        var keysSent = 0
        var keysReleasedAfterFailure = 0
        var keyFileRemoved = false
        var keyRevoked = false
        var completed = false
        var error: String?
    }

    static func sendKeys<Transport: ClientTransport>(
        _ mode: PowerMode, using client: GRPCClient<Transport>, token: String,
        hold: @Sendable (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }
    ) async -> (sent: Int, released: Int, ok: Bool) {
        var options = CallOptions.defaults
        options.timeout = .milliseconds(3000); options.waitForReady = false
        let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        func send(_ code: Int32, down: Bool) async -> Bool {
            var event = Android_Emulation_Control_KeyboardEvent()
            event.codeType = .evdev; event.eventType = down ? .keydown : .keyup; event.keyCode = code
            return (try? await controller.sendKey(event, metadata: ["authorization": "Bearer \(token)"], options: options)) != nil
        }
        var pressed: [Int32] = [], sent = 0, heldOnce = false
        for step in steps(mode) {
            if !step.down, holds(mode), !heldOnce { heldOnce = true; await hold(holdMS) }
            guard await send(step.code, down: step.down) else {
                // Lift what this call pressed, once each, so no key stays down in Android.
                var released = 0
                for code in pressed.reversed() {
                    if await send(code, down: false) { released += 1 }
                }
                return (sent, released, false)
            }
            sent += 1
            if step.down { pressed.append(step.code) } else { pressed.removeAll { $0 == step.code } }
        }
        return (sent, 0, true)
    }

    /// Full lifecycle: discover → validate (game must be exited) → one public
    /// key → send → revoke. No retry.
    static func powerKey(mode: PowerMode, usbOffConfirmed: Bool) async -> PowerReport {
        var report = PowerReport(); report.mode = mode.rawValue
        var file: OwnedPublicKey?, kid: String?, active: String?
        do {
            let config = try RuntimeDiscovery.session(usbDebuggingOff: usbOffConfirmed, gameExited: true)
            _ = try StatusSession.validate(config, requireGameExited: true)
            _ = try KeyStore.validate(config)
            let keyPath = config.jwks + "/egw-power.jwk"
            guard !FileManager.default.fileExists(atPath: keyPath) else { throw SessionFailure.keyExistsOrInaccessible }
            report.instanceVerified = true
            let key = SessionKey(); kid = key.kid; active = config.active
            file = try OwnedPublicKey(path: keyPath, data: key.publicSet()); report.keyCreated = true
            report.keyLoaded = try await StatusSession.waitForKey(key.kid, active: config.active, present: true)
            guard report.keyLoaded else { throw SessionFailure.keyNotLoaded }
            let transport = try StatusClient.makeTransport(host: "127.0.0.1", port: RuntimeDiscovery.grpcPort, security: "plaintext")
            // One token for the whole ~2 s sequence (valid 120 s), scoped to sendKey only.
            let token = try key.token(now: Int(Date().timeIntervalSince1970), audiences: [TextSender.keyMethod])
            let result = try await withGRPCClient(transport: transport) { client in
                await sendKeys(mode, using: client, token: token)
            }
            report.keysSent = result.sent; report.keysReleasedAfterFailure = result.released
            if !result.ok { report.error = "send_key_failed" }
        } catch let failure as SessionFailure { report.error = failure.rawValue }
        catch { report.error = "local_or_transport_failure" }
        if let file, let kid, let active {
            do {
                try file.remove(); report.keyFileRemoved = true
                report.keyRevoked = (try? await StatusSession.waitForKey(kid, active: active, present: false)) ?? false
            } catch { report.error = report.error ?? "key_cleanup_failed" }
            if !report.keyRevoked, report.error == nil { report.error = SessionFailure.keyRevocationUnconfirmed.rawValue }
        }
        report.completed = report.error == nil
        return report
    }

    // MARK: terminate

    struct TerminateReport: Encodable, Sendable {
        var operation = "terminate"
        var state = ""
        var pid: Int32?
        var identityVerified = false
        var signalSent = false
        var exited = false
        var waitedSeconds = 0.0
        var discoveryRemoved = false
        var error: String?
    }

    /// The command line must be this project's Emulator for this AVD with gRPC.
    static func isOurEmulator(command: String) -> Bool {
        command.hasPrefix(RuntimeDiscovery.project + "/.runtime/android-sdk/emulator/")
            && command.contains("-avd " + RuntimeDiscovery.avd) && command.contains("-grpc \(RuntimeDiscovery.grpcPort)")
    }

    static func command(of pid: Int32) -> String? {
        (try? StatusSession.inspect("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exactly one SIGTERM to the discovered instance, re-checking identity just
    /// before sending. Waits up to `timeout` seconds; never escalates.
    static func terminate(timeout: Double = 60,
                          finding: RuntimeDiscovery.Finding = RuntimeDiscovery.find(),
                          commandOf: (Int32) -> String? = command(of:),
                          signal send: (Int32) -> Int32 = { kill($0, SIGTERM) },
                          alive: (Int32) -> Bool = { kill($0, 0) == 0 },
                          sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> TerminateReport {
        var report = TerminateReport(); report.state = finding.state.rawValue
        guard finding.state == .running, let pid = finding.pid else { report.error = "not_running_\(finding.state.rawValue)"; return report }
        report.pid = pid
        guard let command = commandOf(pid), isOurEmulator(command: command) else { report.error = "identity_mismatch"; return report }
        report.identityVerified = true
        guard send(pid) == 0 else { report.error = "signal_failed"; return report }
        report.signalSent = true
        let step = 0.5
        while report.waitedSeconds < timeout {
            if !alive(pid) { report.exited = true; break }
            sleep(step); report.waitedSeconds += step
        }
        if !report.exited { report.error = "still_running_after_\(Int(timeout))s" }
        if let discovery = finding.discovery { report.discoveryRemoved = !FileManager.default.fileExists(atPath: discovery) }
        return report
    }
}
