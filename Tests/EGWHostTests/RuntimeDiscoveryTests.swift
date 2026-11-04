import Testing
@testable import EGWHost

private func candidate(_ pid: Int32) -> RuntimeDiscovery.Candidate {
    .init(pid: pid, path: "/r/pid_\(pid).ini", jwks: "/j/\(pid)", active: "/j/\(pid)/active.jwk")
}

@Suite("Runtime discovery and daily options")
struct RuntimeDiscoveryTests {
    @Test func keepsOnlyOwnPrivateCanonicalDiscoveryFiles() throws {
        let found = try #require(discoveryCandidatesFixture())
        #expect(found.map(\.pid) == [4242])
        #expect(found.first?.jwks == "/j/ours" && found.first?.active == "/j/ours/active.jwk")
    }

    @Test func classifiesEveryState() {
        let alive: (Int32) -> Bool = { $0 == 10 || $0 == 11 }
        #expect(RuntimeDiscovery.classify(candidates: [], alive: alive, emulatorPIDs: []).state == .stopped)
        let starting = RuntimeDiscovery.classify(candidates: [], alive: alive, emulatorPIDs: [10])
        #expect(starting.state == .starting && starting.pid == 10)
        let running = RuntimeDiscovery.classify(candidates: [candidate(10)], alive: alive, emulatorPIDs: [10])
        #expect(running.state == .running && running.pid == 10 && running.jwks == "/j/10")
        // Discovery left behind by a dead process.
        #expect(RuntimeDiscovery.classify(candidates: [candidate(99)], alive: alive, emulatorPIDs: []).state == .lost)
        // A stale file next to a live one still picks the live one.
        #expect(RuntimeDiscovery.classify(candidates: [candidate(99), candidate(10)], alive: alive,
                                          emulatorPIDs: [10]).pid == 10)
        // Two live instances, or an extra Emulator for the same AVD, are never guessed.
        #expect(RuntimeDiscovery.classify(candidates: [candidate(10), candidate(11)], alive: alive,
                                          emulatorPIDs: [10, 11]).state == .ambiguous)
        #expect(RuntimeDiscovery.classify(candidates: [candidate(10)], alive: alive,
                                          emulatorPIDs: [10, 12]).state == .ambiguous)
        #expect(RuntimeDiscovery.classify(candidates: [], alive: alive, emulatorPIDs: [12, 13]).state == .ambiguous)
    }

    @Test func parsesEmulatorProcessesForThisAVDOnly() {
        let root = RuntimeDiscovery.project + "/.runtime/android-sdk/emulator/"
        let text = """
          101 \(root)qemu/darwin-aarch64/qemu-system-aarch64 -avd \(RuntimeDiscovery.avd) -grpc 8554
          102 /Applications/Other.app/emulator -avd \(RuntimeDiscovery.avd)
          103 \(root)emulator -avd some_other_avd
          104 /bin/zsh
        """
        #expect(RuntimeDiscovery.parseEmulatorPIDs(text) == [101])
    }

    @Test func sessionNeedsExactlyOneRunningInstance() throws {
        let running = RuntimeDiscovery.Finding(state: .running, pid: 10, discovery: "/r/pid_10.ini",
                                               jwks: "/j/10", active: "/j/10/active.jwk")
        let config = try RuntimeDiscovery.session(usbDebuggingOff: true, gameExited: false, finding: running)
        #expect(config.pid == 10 && config.usbDebuggingOff && !config.gameExited)
        #expect(config.project == RuntimeDiscovery.project && config.discovery == "/r/pid_10.ini")
        for state in [RuntimeDiscovery.State.stopped, .starting, .lost, .ambiguous] {
            let finding = RuntimeDiscovery.Finding(state: state, pid: 10, discovery: nil, jwks: nil, active: nil)
            #expect(throws: SessionFailure.self) {
                _ = try RuntimeDiscovery.session(usbDebuggingOff: true, gameExited: true, finding: finding)
            }
        }
    }

    @Test func statusReportAndExitCodes() {
        let finding = RuntimeDiscovery.Finding(state: .stopped, pid: nil, discovery: nil, jwks: nil, active: nil)
        let report = RuntimeStatus.report(finding)
        #expect(report["state"] as? String == "stopped" && report["rpcAttempted"] as? Bool == false)
        #expect([RuntimeDiscovery.State.running, .stopped, .starting, .lost, .ambiguous].map(RuntimeStatus.exitCode) == [0, 3, 4, 5, 6])
    }

    @Test func gameViewAutoOptions() throws {
        let auto = try GameViewOptions.parse(["game-view", "--auto", "--usb-off-confirmed", "--game-in-use", "--seconds", "7200"])
        #expect(auto.auto && auto.usbOffConfirmed && auto.session == nil && auto.seconds == 7200 && auto.gameInUse)
        let bad: [[String]] = [
            ["game-view", "--auto", "--seconds", "60"],                                      // no USB statement
            ["game-view", "--session", "/s.json", "--usb-off-confirmed", "--seconds", "60"], // statement only for auto
            ["game-view", "--auto", "--usb-off-confirmed", "--session", "/s.json", "--seconds", "60"],
            ["game-view", "--auto", "--usb-off-confirmed", "--seconds", "14401"],
            ["game-view", "--auto", "--auto", "--usb-off-confirmed", "--seconds", "60"],
        ]
        for args in bad { #expect(throws: ProbeFailure.self) { _ = try GameViewOptions.parse(args) } }
    }
}
