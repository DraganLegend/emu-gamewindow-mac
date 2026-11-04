import AppKit
import Darwin
import Foundation
import GRPCCore
import InputCore

// Replan 20261101 step 1 (window half): our own window shows streamScreenshot
// and turns its own left mouse / mapped keys into sendTouch. No event tap, no
// TCC input permission, no other process's window. The keymap is edited in the
// window (click a place, press a key) and kept in GameKeymapStore.
struct GameViewOptions: Sendable {
    /// Hand-written session file; nil with `auto`.
    let session: String?
    let seconds: Int
    let flipFrames: Bool
    let gameInUse: Bool
    var viewTurns = 0
    var streamMap: StreamRotationMap = .cw
    /// discover the running instance instead of reading a session file.
    var auto = false
    /// Operator's statement that USB debugging is OFF (required with `auto`).
    var usbOffConfirmed = false
    /// Opt-in fast frame path: MMAP shared memory + Metal display.
    var fastPath = false
    /// How fast-path frames are presented (`--present`); ignored without the fast path.
    /// Default `nosync3`: lowest measured latency without visible tearing.
    var presentMode: PresentMode = .nosync3
    static let secondsRange = 30...14_400

    static func parse(_ args: [String]) throws -> Self {
        guard args.first == "game-view" else { throw ProbeOptions.invalid("game-view 語法不合法。") }
        var values: [String: String] = [:]
        var flip = false, gameInUse = false, auto = false, usbOff = false, fast = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--auto":
                guard !auto else { throw ProbeOptions.invalid("選項不可重複。") }
                auto = true; index += 1
            case "--fast-path":
                guard !fast else { throw ProbeOptions.invalid("選項不可重複。") }
                fast = true; index += 1
            case "--usb-off-confirmed":
                guard !usbOff else { throw ProbeOptions.invalid("選項不可重複。") }
                usbOff = true; index += 1
            case "--flip-frames":
                guard !flip else { throw ProbeOptions.invalid("選項不可重複。") }
                flip = true; index += 1
            case "--game-in-use":
                guard !gameInUse else { throw ProbeOptions.invalid("選項不可重複。") }
                gameInUse = true; index += 1
            case "--session", "--seconds", "--rotate", "--stream-rotation-map", "--present":
                guard values[args[index]] == nil, index + 1 < args.count else { throw ProbeOptions.invalid("選項重複或缺少值。") }
                values[args[index]] = args[index + 1]; index += 2
            default:
                throw ProbeOptions.invalid("game-view 選項不合法；請勿透過命令列提供憑證。")
            }
        }
        guard let text = values["--seconds"], let seconds = Int(text), Self.secondsRange.contains(seconds),
              (values["--session"] == nil) == auto else {
            throw ProbeOptions.invalid("game-view 需要 --session 或 --auto（擇一）與 --seconds 30～14400。")
        }
        guard auto == usbOff else {
            throw ProbeOptions.invalid("--auto 必須搭配 --usb-off-confirmed（且只用於 --auto）。")
        }
        var result = Self(session: values["--session"], seconds: seconds, flipFrames: flip, gameInUse: gameInUse)
        result.auto = auto; result.usbOffConfirmed = usbOff; result.fastPath = fast
        if let text = values["--rotate"] {
            guard let degrees = Int(text), [0, 90, 180, 270].contains(degrees) else {
                throw ProbeOptions.invalid("--rotate 只接受 0、90、180、270。")
            }
            result.viewTurns = degrees / 90
        }
        if let text = values["--stream-rotation-map"] {
            guard let map = StreamRotationMap(rawValue: text) else {
                throw ProbeOptions.invalid("--stream-rotation-map 只接受 cw、ccw、none。")
            }
            result.streamMap = map
        }
        if let text = values["--present"] {
            guard let mode = PresentMode(rawValue: text) else {
                throw ProbeOptions.invalid("--present 只接受 standard、low、nosync、nosync3。")
            }
            result.presentMode = mode
        }
        return result
    }

}

struct GameViewReport: Encodable, Sendable {
    var phase = "game-view"
    var transportCompleted = false
    var instanceVerified = false
    var keyCreated = false
    var keyLoaded = false
    var keyFileRemoved = false
    var keyRevoked = false
    var gameInUse = false
    var requestedSeconds = 0
    var windowShown = false
    var statusNote = ""
    var framesShown = 0
    var touchRequests = 0
    var touchFailures = 0
    var keyEvents = 0
    var keysConsumed = 0
    var mouseEvents = 0
    var keymapBindings = 0
    var keymapSaves = 0
    var keymapSaveFailures = 0
    var contactsHeldAtEnd = 0
    var contactsDrained = false
    var maxHeldContacts = 0
    var joystickBound = false
    var viewTurnsAtEnd = 0
    var lastStreamRotation = 0
    var streamRotationMap = "cw"
    var geometryChanges = 0
    /// Quit (menu / Dock) or SIGINT/SIGTERM turned into a normal close.
    var quitRequests = 0
    var resizes = 0
    var textModeSwitches = 0
    var textSends = 0
    var textFailures = 0
    var androidKeys = 0
    /// Resource use: this window process over the session, and
    /// the Emulator sampled with `ps` every 30 s (first after 10 s).
    var hostCpuSeconds = 0.0
    var hostCpuPercent = 0.0
    var hostMaxRssMiB = 0.0
    var emulatorPerf: PerfSampler.Summary?
    /// "grpc" or "mmap"; "layer", "metal-nocopy" or "metal-copy"; why the fast path was not used.
    var frameTransport = "grpc"
    var renderer = "layer"
    var presentMode: String?
    var drawOnArrival: Bool?
    var fastPathFallback: String?
    var fastDrawFailures = 0
    /// Stage timings: received → taken by the display link, taken → on screen
    /// (fast path), frames replaced before being shown, and thermal pressure.
    var displayWaitMs: StageStats.Summary?
    var presentMs: StageStats.Summary?
    var framesSuperseded = 0
    var thermalWorst: String?
    var thermalCounts: [String: Int] = [:]
    var screenshots = 0
    var crossedTokenExpiry = false
    var streamError: String?
    var summary: StreamSummary?
    var error: String?
    var rpcCode: Int?
    var diagnostic: StatusDiagnostic?
    // Fixed: no synthetic input exists in this command; only our own window's events.
    let syntheticInput = false
    let framesStored = false
}

private struct GameSnapshot: Sendable {
    let note: String
    let frames: Int
    let touches: Int
    let failures: Int
    let held: Int
    let drained: Bool
    let expired: Bool
    let streamError: String?
    let keyEvents: Int
    let keysConsumed: Int
    let mouseEvents: Int
    let bindings: Int
    let saves: Int
    let saveFailures: Int
    let maxHeld: Int
    let joystick: Bool
    let viewTurns: Int
    let streamRotation: Int
    let geometryChanges: Int
    let quits: Int
    let resizes: Int
    let textModes: Int
    let textSends: Int
    let textFailures: Int
    let androidKeys: Int
    let screenshots: Int
    let emulatorPerf: PerfSampler.Summary?
    let wallSeconds: Double
    let fastDrawFailures: Int
    let displayWait: StageStats.Summary?
    let present: StageStats.Summary?
    let superseded: Int
    let thermal: [String]
}

/// Dock / menu Quit and SIGINT/SIGTERM must not skip the drain: they only
/// close the window, and the pump then releases contacts and revokes the key.
/// SIGKILL (Force Quit) cannot be intercepted.
@MainActor
final class GameQuitGuard: NSObject, NSApplicationDelegate {
    private(set) var requests = 0
    weak var host: GameWindowHost?
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, sig_t?)] = []

    func install(_ host: GameWindowHost) {
        self.host = host
        NSApp.delegate = self
        for number in [SIGINT, SIGTERM] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.request() } }
            source.resume(); sources.append(source)
        }
    }

    func uninstall() {
        for source in sources { source.cancel() }
        for (number, handler) in previous { signal(number, handler) }
        sources = []; previous = []
        if NSApp.delegate === self { NSApp.delegate = nil }
    }

    private func request() {
        requests += 1
        GameViewSession.note("quit-requested")
        host?.closeWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        request()
        return .terminateCancel
    }
}


private actor GameRunFlag {
    var finished = false
    var streamError: String?
    func finish(_ error: String? = nil) { finished = true; streamError = error }
}

enum GameViewSession {
    /// Fixed-vocabulary progress breadcrumbs on stderr; never raw errors or values.
    static func note(_ stage: StaticString) {
        FileHandle.standardError.write(Data(("gv:\(stage)\n").utf8))
    }

    static func outcome(_ result: StatusOutcome) -> DispatchOutcome {
        if !result.rpcAttempted { return .notSent }
        if result.rpcCode == 0 { return .acknowledged }
        if result.rpcCode == RPCError.Code.deadlineExceeded.rawValue { return .timedOut }
        return .failed
    }

    @MainActor
    private static func pump(_ host: GameWindowHost, flag: GameRunFlag, seconds: Int) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
        while !host.closed, !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            if await flag.finished { break }
            // Input upkeep and drawing run on the window's display link (one per
            // screen refresh); this loop only watches for the end of the session.
            try? await Task.sleep(for: .milliseconds(50))
        }
        note(host.closed ? "window-closed" : "loop-ended")
        // Normal exit path: stop the mapping, let cleanup releases finish, then close.
        host.beginShutdown()
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !host.drained, DispatchTime.now().uptimeNanoseconds < end {
            host.tick()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// AppKit owns the main thread here: `NSApplication.run()` delivers events and
    /// services the main queue, so the async session runs inside it. The earlier
    /// hand-rolled event polling let the Swift main loop return (exit 0) right
    /// after the window appeared.
    @MainActor
    static func execute(_ options: GameViewOptions) -> GameViewReport {
        var result: GameViewReport?
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            result = await run(options)
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: true)
            }
        }
        app.run()
        var failed = GameViewReport()
        failed.error = "app_loop_ended_early"
        return result ?? failed
    }

    static let frameMappingPath = HostStorage.build + "/frames-\(getpid()).raw"

    /// Mapping sized for either orientation of the AVD display, plus a Metal
    /// renderer over it. Any failure keeps the gRPC path and says why.
    static func prepareFastPath(path: String = frameMappingPath,
                                avdConfig: String = SpacePolicy.avdDirectory + "/config.ini")
        -> (mapping: FrameMapping?, renderer: MetalFrameRenderer?, fallback: String?) {
        guard let text = FileManager.default.contents(atPath: avdConfig).map({ String(decoding: $0, as: UTF8.self) }),
              let display = FrameMapping.avdDisplay(configText: text),
              let bytes = FrameMapping.regionBytes(width: display.0, height: display.1) else {
            return (nil, nil, "avd_display_unknown")
        }
        guard let mapping = try? FrameMapping(path: path, length: bytes) else { return (nil, nil, "mapping_failed") }
        guard let renderer = MetalFrameRenderer(pointer: mapping.pointer, length: mapping.length) else {
            mapping.remove(); return (nil, nil, "metal_unavailable")
        }
        return (mapping, renderer, nil)
    }

    @MainActor
    private static func run(_ options: GameViewOptions) async -> GameViewReport {
        var report = GameViewReport()
        note("start")
        atexit { FileHandle.standardError.write(Data(("gv:atexit\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n").utf8)) }
        report.gameInUse = options.gameInUse; report.requestedSeconds = options.seconds
        report.streamRotationMap = options.streamMap.rawValue
        var file: OwnedPublicKey?
        var mapping: FrameMapping?
        var renderer: MetalFrameRenderer?
        var kid: String?
        var activePath: String?
        let audit = StreamAudit()
        do {
            let profile = try GameKeymapStore.load()
            let config: SessionConfig
            if let path = options.session {
                try StatusSession.owned(path)
                config = try JSONDecoder().decode(SessionConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } else {
                // Without --game-in-use the operator stated the game is closed.
                config = try RuntimeDiscovery.session(usbDebuggingOff: options.usbOffConfirmed,
                                                      gameExited: !options.gameInUse)
            }
            let requireExit = !options.gameInUse
            let baseline = try StatusSession.validate(config, requireGameExited: requireExit)
            _ = try KeyStore.validate(config)
            let keyPath = config.jwks + "/egw-gameview.jwk"
            guard !FileManager.default.fileExists(atPath: keyPath) else { throw SessionFailure.keyExistsOrInaccessible }
            report.instanceVerified = true
            note("validated")
            let key = SessionKey(); kid = key.kid; activePath = config.active
            let publicFile = try OwnedPublicKey(path: keyPath, data: key.publicSet())
            file = publicFile; report.keyCreated = true
            report.keyLoaded = try await StatusSession.waitForKey(key.kid, active: config.active, present: true)
            guard report.keyLoaded else { throw SessionFailure.keyNotLoaded }
            let streamToken = try key.token(now: Int(Date().timeIntervalSince1970), audiences: [StreamSpike.streamMethod])
            let expectedKid = key.kid
            let transport = try StatusClient.makeTransport(host: "127.0.0.1", port: RuntimeDiscovery.grpcPort, security: "plaintext")
            var streamOptions = StreamSpikeOptions(session: options.session ?? "auto", seconds: options.seconds,
                                                   width: 0, height: 0, gameInUse: options.gameInUse)
            if options.fastPath {
                let fast = Self.prepareFastPath()
                mapping = fast.mapping; renderer = fast.renderer; report.fastPathFallback = fast.fallback
            }
            report.frameTransport = mapping == nil ? "grpc" : "mmap"
            report.renderer = renderer?.mode.rawValue ?? "layer"
            report.presentMode = renderer == nil ? nil : options.presentMode.rawValue
            report.drawOnArrival = renderer == nil ? nil : options.presentMode.drawsOnArrival
            streamOptions.mmapHandle = mapping?.handle; streamOptions.mmapCapacity = mapping?.length
            let fastMapping = mapping, fastRenderer = renderer
            let frozenStreamOptions = streamOptions
            // A command-line process with no window yet can otherwise be reaped by macOS.
            ProcessInfo.processInfo.disableSuddenTermination()
            ProcessInfo.processInfo.disableAutomaticTermination("egw-game-view")
            let started = DispatchTime.now().uptimeNanoseconds
            let snapshot: GameSnapshot = try await withGRPCClient(transport: transport) { client in
                @Sendable func verify() throws {
                    // Freshness applies to the start-up confirmation only; everything else is re-checked.
                    _ = try StatusSession.validate(config, expected: baseline, requireGameExited: requireExit, maxAge: nil)
                    try StatusSession.owned(keyPath)
                    var info = stat()
                    guard lstat(keyPath, &info) == 0, info.st_dev == publicFile.device,
                          info.st_ino == publicFile.inode else { throw SessionFailure.sessionChanged }
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config.active)))
                    guard let keys = (object as? [String: Any])?["keys"] as? [[String: Any]],
                          keys.count == 1, keys[0]["kid"] as? String == expectedKid else { throw SessionFailure.sessionChanged }
                }
                try verify(); try Task.checkCancellation()
                let host = GameWindowHost(profile: profile, flipFrames: options.flipFrames,
                                          viewTurns: options.viewTurns, streamMap: options.streamMap, sendTouch: { request in
                    // Re-signed per send: the in-memory key outlives the 120 s token. No retry.
                    let token = (try? key.token(now: Int(Date().timeIntervalSince1970),
                                                audiences: [TouchClient.touchMethod])) ?? ""
                    let change = request.change
                    return outcome(await TouchClient.send(using: client,
                        contact: .init(id: change.id, x: Int32(change.point.x), y: Int32(change.point.y),
                                       pressure: Int32(change.pressure)), token: token))
                })
                host.officialPID = config.pid
                host.fastMapping = fastMapping; host.fastRenderer = fastRenderer; host.presentMode = options.presentMode
                host.sendText = { text in
                    // Fresh token per call, scoped to the one method; the key never leaves memory.
                    let result = await TextSender.send(text, using: client) { audience in
                        (try? key.token(now: Int(Date().timeIntervalSince1970), audiences: [audience])) ?? ""
                    }
                    if case .success = result { return true }
                    return false
                }
                host.sendAndroidKey = { androidKey in
                    guard let token = try? key.token(now: Int(Date().timeIntervalSince1970), audiences: [TextSender.keyMethod]) else { return false }
                    return await AndroidKey.send(androidKey, using: client, token: token)
                }
                host.installMenu()
                let quitGuard = GameQuitGuard()
                quitGuard.install(host)
                note("client-up")
                let flag = GameRunFlag()
                let mailbox = host.mailbox
                let drawOnArrival = host.drawsOnArrival
                return try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await StreamSpike.stream(using: client, token: streamToken, options: frozenStreamOptions,
                                                         audit: audit, verify: verify, onFrame: { image in
                                // Never wait for drawing: hand over the newest frame and keep receiving.
                                let width = Int(image.format.width), height = Int(image.format.height)
                                let rotation = image.format.rotation.rotation.rawValue
                                let payload: FrameMailbox.Payload
                                if fastMapping != nil {
                                    guard image.image.isEmpty, width > 0, height > 0 else { return }
                                    payload = .mapped
                                } else {
                                    guard let cg = FrameRenderer.image(rgba: image.image, width: width, height: height) else { return }
                                    payload = .image(cg)
                                }
                                // First frame: the window (and its display link) does not exist yet.
                                // No-vsync modes: draw now instead of waiting for the next tick.
                                if mailbox.put(width: width, height: height, rotation: rotation, payload: payload) || drawOnArrival {
                                    Task { @MainActor in host.drawLatest() }
                                }
                            })
                            await flag.finish()
                        } catch is CancellationError { await flag.finish() }
                        catch let error as RPCError { await flag.finish("rpc_\(error.code.rawValue)") }
                        catch let error as SessionFailure { await flag.finish(error.rawValue) }
                        catch { await flag.finish("local_failure") }
                    }
                    let perf = PerfLog(), emulatorPID = config.pid
                    let sampler = Task.detached {
                        var delay = 10
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(delay)); delay = 30
                            if Task.isCancelled { break }
                            if let sample = PerfSampler.sample(pid: emulatorPID) { await perf.add(sample) }
                            await perf.addThermal(ThermalSampler.label(ProcessInfo.processInfo.thermalState))
                        }
                    }
                    await pump(host, flag: flag, seconds: options.seconds)
                    sampler.cancel()
                    let emulatorPerf = PerfSampler.summarize(await perf.samples)
                    let thermal = await perf.thermal
                    note("pump-done")
                    group.cancelAll()
                    try await group.waitForAll()
                    let expired = DispatchTime.now().uptimeNanoseconds - started >= UInt64(StreamSpike.tokenLifetimeSeconds) * 1_000_000_000
                    let streamError = await flag.streamError
                    let result = GameSnapshot(
                        note: host.statusNote, frames: host.framesShown, touches: host.touchRequests,
                        failures: host.touchFailures, held: host.heldContacts, drained: host.drained,
                        expired: expired, streamError: streamError, keyEvents: host.keyEvents,
                        keysConsumed: host.keysConsumed, mouseEvents: host.mouseEvents,
                        bindings: host.profile.bindings.count, saves: host.keymapSaves,
                        saveFailures: host.keymapSaveFailures, maxHeld: host.maxHeldContacts,
                        joystick: host.profile.joystick != nil, viewTurns: host.viewTurns,
                        streamRotation: host.lastStreamRotation, geometryChanges: host.geometryChanges,
                        quits: quitGuard.requests, resizes: host.resizes, textModes: host.textModeSwitches,
                        textSends: host.textSends, textFailures: host.textFailures,
                        androidKeys: host.androidKeys, screenshots: host.screenshots,
                        emulatorPerf: emulatorPerf,
                        wallSeconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000,
                        fastDrawFailures: host.fastDrawFailures,
                        displayWait: host.stages.waitSummary, present: host.stages.presentSummary,
                        superseded: host.mailbox.supersededCount, thermal: thermal)
                    host.closeWindow()
                    quitGuard.uninstall()
                    return result
                }
            }
            note("client-closed")
            report.statusNote = snapshot.note; report.framesShown = snapshot.frames
            report.touchRequests = snapshot.touches; report.touchFailures = snapshot.failures
            report.contactsHeldAtEnd = snapshot.held; report.contactsDrained = snapshot.drained
            report.crossedTokenExpiry = snapshot.expired; report.streamError = snapshot.streamError
            report.keyEvents = snapshot.keyEvents; report.keysConsumed = snapshot.keysConsumed
            report.mouseEvents = snapshot.mouseEvents; report.keymapBindings = snapshot.bindings
            report.keymapSaves = snapshot.saves; report.keymapSaveFailures = snapshot.saveFailures
            report.windowShown = snapshot.frames > 0
            report.maxHeldContacts = snapshot.maxHeld; report.joystickBound = snapshot.joystick
            report.viewTurnsAtEnd = snapshot.viewTurns; report.lastStreamRotation = snapshot.streamRotation
            report.geometryChanges = snapshot.geometryChanges; report.quitRequests = snapshot.quits
            report.resizes = snapshot.resizes; report.textModeSwitches = snapshot.textModes
            report.textSends = snapshot.textSends; report.textFailures = snapshot.textFailures
            report.androidKeys = snapshot.androidKeys; report.screenshots = snapshot.screenshots
            report.emulatorPerf = snapshot.emulatorPerf
            report.fastDrawFailures = snapshot.fastDrawFailures
            report.displayWaitMs = snapshot.displayWait; report.presentMs = snapshot.present
            report.framesSuperseded = snapshot.superseded
            report.thermalWorst = ThermalSampler.worst(snapshot.thermal)
            report.thermalCounts = Dictionary(snapshot.thermal.map { ($0, 1) }, uniquingKeysWith: +)
            let usage = StreamSpike.cpuAndRSS()
            report.hostCpuSeconds = (usage.0 * 10).rounded() / 10; report.hostMaxRssMiB = (usage.1 * 10).rounded() / 10
            report.hostCpuPercent = PerfSampler.percent(cpuSeconds: usage.0, wallSeconds: snapshot.wallSeconds)
        } catch let error as RPCError {
            report.error = "rpc_failed"; report.rpcCode = error.code.rawValue
            report.diagnostic = StatusDiagnostic.classify(error)
        } catch let error as SessionFailure { report.error = error.rawValue }
        catch let error as InputCoreError { report.error = "invalid_profile_\(error)" }
        catch is CancellationError { report.error = "cancelled" }
        catch { report.error = "local_failure" }
        note("cleanup")
        mapping?.remove()   // the stream has ended; remove exactly our mapping file
        let stats = await audit.snapshot()
        if stats.frames > 0 { report.summary = stats.summary() }
        if let file, let kid, let activePath {
            let removed = await Task.detached { () -> (Bool, Bool) in
                do {
                    try file.remove()
                    return (true, (try? await StatusSession.waitForKey(kid, active: activePath, present: false)) ?? false)
                } catch { return (false, false) }
            }.value
            report.keyFileRemoved = removed.0; report.keyRevoked = removed.1
            if !removed.1 { report.error = SessionFailure.keyRevocationUnconfirmed.rawValue }
        }
        report.transportCompleted = report.error == nil && report.keyRevoked && report.framesShown > 0
            && report.contactsDrained && report.contactsHeldAtEnd == 0
        return report
    }
}
