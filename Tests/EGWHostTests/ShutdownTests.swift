import Testing
@testable import EGWHost

private let ours = RuntimeDiscovery.project + "/.runtime/android-sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd "
    + RuntimeDiscovery.avd + " -grpc 8554 -grpc-use-jwt"
private func running(_ pid: Int32) -> RuntimeDiscovery.Finding {
    .init(state: .running, pid: pid, discovery: nil, jwks: "/j", active: "/j/active.jwk")
}

/// Counts signals and simulates the process ending after `exitAfter` polls.
private final class FakeProcess: @unchecked Sendable {
    var signals = 0, polls = 0
    let exitAfter: Int
    init(exitAfter: Int) { self.exitAfter = exitAfter }
    func signal(_ pid: Int32) -> Int32 { signals += 1; return 0 }
    func alive(_ pid: Int32) -> Bool { polls += 1; return signals == 0 || polls <= exitAfter }
}

@Suite("CLI shutdown: power key and one SIGTERM")
struct ShutdownTests {
    @Test func powerKeySequencesAreBalanced() {
        #expect(Shutdown.steps(.short).map(\.code) == [116, 116] && !Shutdown.holds(.short))
        #expect(Shutdown.steps(.long).map(\.down) == [true, false] && Shutdown.holds(.long))
        let chord = Shutdown.steps(.chord)
        #expect(chord.map(\.code) == [115, 116, 116, 115] && chord.map(\.down) == [true, true, false, false])
    }

    @Test func identityCheck() {
        #expect(Shutdown.isOurEmulator(command: ours))
        #expect(!Shutdown.isOurEmulator(command: "/Applications/Other/emulator -avd " + RuntimeDiscovery.avd + " -grpc 8554"))
        #expect(!Shutdown.isOurEmulator(command: RuntimeDiscovery.project + "/.runtime/android-sdk/emulator/emulator -avd other -grpc 8554"))
        #expect(!Shutdown.isOurEmulator(command: RuntimeDiscovery.project + "/.runtime/android-sdk/emulator/emulator -avd " + RuntimeDiscovery.avd))
    }

    @Test func refusesWithoutExactlyOneVerifiedInstance() {
        for state in [RuntimeDiscovery.State.stopped, .starting, .lost, .ambiguous] {
            let fake = FakeProcess(exitAfter: 0)
            let r = Shutdown.terminate(finding: .init(state: state, pid: 9, discovery: nil, jwks: nil, active: nil),
                                         commandOf: { _ in ours }, signal: fake.signal, alive: fake.alive, sleep: { _ in })
            #expect(!r.signalSent && fake.signals == 0 && r.error?.hasPrefix("not_running") == true)
        }
        let fake = FakeProcess(exitAfter: 0)
        let r = Shutdown.terminate(finding: running(9), commandOf: { _ in "/bin/zsh" },
                                     signal: fake.signal, alive: fake.alive, sleep: { _ in })
        #expect(r.error == "identity_mismatch" && fake.signals == 0)
    }

    @Test func oneSignalThenWaitsForExit() {
        let fake = FakeProcess(exitAfter: 4)
        let r = Shutdown.terminate(finding: running(9), commandOf: { _ in ours },
                                     signal: fake.signal, alive: fake.alive, sleep: { _ in })
        #expect(r.signalSent && r.exited && r.error == nil && fake.signals == 1 && r.waitedSeconds == 2.0)
    }

    @Test func timeoutNeverEscalates() {
        let fake = FakeProcess(exitAfter: .max)
        let r = Shutdown.terminate(timeout: 3, finding: running(9), commandOf: { _ in ours },
                                     signal: fake.signal, alive: fake.alive, sleep: { _ in })
        #expect(!r.exited && fake.signals == 1 && r.error == "still_running_after_3s")
    }

    @Test func launcherStopRules() {
        var model = LauncherModel(state: .running)
        #expect(model.canStop)
        model.playing = true
        #expect(!model.canStop)
        model.playing = false; model.stopping = true
        #expect(!model.canStop && !model.canPlay && !model.canQuit)
        #expect(LauncherModel.stopArguments(script: "/p/egw", host: false) == ["/p/egw", "stop", "--yes", "--android"])
        #expect(LauncherModel.stopArguments(script: "/p/egw", host: true) == ["/p/egw", "stop", "--yes", "--host"])
    }
}
