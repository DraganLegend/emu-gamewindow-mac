import GRPCCore
import Testing
@testable import EGWHost

@Suite("Stream spike receive-only contract", .timeLimit(.minutes(2)))
struct StreamSpikeTests {
    @Test func parsesFixedOptions() throws {
        let ok = try StreamSpikeOptions.parse(["stream-spike", "--session", "/s.json", "--seconds", "30",
                                               "--width", "360", "--height", "640", "--game-in-use"])
        #expect(ok.seconds == 30 && ok.width == 360 && ok.height == 640 && ok.gameInUse)
        let native = try StreamSpikeOptions.parse(["stream-spike", "--session", "/s.json", "--seconds", "5"])
        #expect(native.width == 0 && native.height == 0 && !native.gameInUse)
        let bad: [[String]] = [
            ["stream-spike", "--seconds", "30"],
            ["stream-spike", "--session", "/s.json", "--seconds", "4"],
            ["stream-spike", "--session", "/s.json", "--seconds", "301"],
            ["stream-spike", "--session", "/s.json", "--seconds", "30", "--width", "360"],
            ["stream-spike", "--session", "/s.json", "--seconds", "30", "--width", "10", "--height", "10"],
            ["stream-spike", "--session", "/s.json", "--seconds", "30", "--token", "x"],
            ["stream-spike", "--session", "/s.json", "--session", "/t.json", "--seconds", "30"],
            ["stream-spike", "--session", "/s.json", "--seconds", "30", "--game-in-use", "--game-in-use"],
        ]
        for args in bad { #expect(throws: ProbeFailure.self) { _ = try StreamSpikeOptions.parse(args) } }
    }

    @Test func statsArithmetic() {
        var stats = StreamStats()
        let size = 64 * 64 * 4
        stats.record(seq: 0, emulatorUs: 1000, wallUs: 6000, arrivalNs: 0, width: 64, height: 64, rotation: 0, payloadBytes: size)
        stats.record(seq: 1, emulatorUs: 1000, wallUs: 6000, arrivalNs: 10_000_000, width: 64, height: 64, rotation: 0, payloadBytes: size)
        stats.record(seq: 3, emulatorUs: 1000, wallUs: 6000, arrivalNs: 30_000_000, width: 64, height: 64, rotation: 0, payloadBytes: size - 1)
        stats.record(seq: 3, emulatorUs: 0, wallUs: 6000, arrivalNs: 30_000_000, width: 64, height: 64, rotation: 0, payloadBytes: size)
        let s = stats.summary()
        #expect(s.frames == 4 && s.droppedFrames == 1 && s.seqRegressions == 1 && s.invalidFrames == 1)
        #expect(s.bytes == size * 4 - 1)
        #expect(s.intervalMsMax == 20 && s.intervalMsP50 == 10)
        #expect(s.latencyMsP50 == 5 && s.latencyMsP95 == 5)
        #expect(s.seconds == 0.03 && s.fps == 100)
        #expect(StreamStats().summary().frames == 0 && StreamStats().summary().fps == 0)
    }

    @Test func tokenCoversStreamAndKeyOnly() throws {
        #expect(try verifySessionKeyContract(audiences: [StreamSpike.streamMethod]))
        #expect(try verifySessionKeyContract(audiences: [StreamSpike.streamMethod,
            "/android.emulation.control.EmulatorController/sendKey"]))
        #expect(throws: SessionFailure.self) {
            _ = try SessionKey().token(now: 1234, audiences: ["/android.emulation.control.EmulatorController/setVmState"])
        }
    }

    @Test func diagnosticMessageIsBoundedAndCredentialFree() {
        #expect(StreamSpike.safeMessage("display is disabled") == "display is disabled")
        #expect(StreamSpike.safeMessage("") == nil)
        #expect(StreamSpike.safeMessage("Bearer abc") == nil)
        #expect(StreamSpike.safeMessage("token eyJhbGciOi") == nil)
        #expect(StreamSpike.safeMessage(String(repeating: "a", count: 201)) == nil)
        #expect(StreamSpike.safeMessage("bad\u{7}byte") == nil)
        #expect(StreamSpike.safeMessage("中文") == nil)
    }

    @Test func serverEndsStreamBeforeDeadline() async throws {
        let (stats, requests, failure) = try await runStream(seconds: 30, frames: 12)
        #expect(failure is CancellationError)
        let s = stats.summary()
        #expect(s.frames == 12 && s.invalidFrames == 0 && s.droppedFrames == 0 && s.seqRegressions == 0)
        #expect(s.width == 64 && s.height == 64)
        #expect(await requests.count == 1)
        #expect(await requests.lastFormat?.width == 0)
    }

    @Test func fullSizeFramesExceedingOneMiBAreAccepted() async throws {
        // 1000x1000x4 = 4 MB, like a real 720x1280 RGBA frame; the default 1 MiB limit failed live.
        let (stats, _, failure) = try await runStream(seconds: 30, frames: 4, side: 1000)
        #expect(failure is CancellationError)
        let s = stats.summary()
        #expect(s.frames == 4 && s.invalidFrames == 0 && s.bytes == 4 * 4_000_000)
    }

    @Test func silentStreamStopsOnTimerNotOnNextFrame() async throws {
        // Static screen: one frame, then nothing. Live, this ran to the RPC deadline (code 4).
        let (stats, requests, failure) = try await runStream(seconds: 5, frames: 1, idle: true)
        #expect(failure is CancellationError)
        #expect(stats.frames == 1)
        // The client must stop at ~5 s even though the server stays silent for 12 s.
        let seconds = await requests.clientSeconds
        #expect(seconds >= 4.5 && seconds < 8)
    }

    @Test func clientStopsAtRequestedDuration() async throws {
        let (stats, _, failure) = try await runStream(seconds: 5, frames: nil)
        #expect(failure is CancellationError)
        let s = stats.summary()
        #expect(s.frames > 50 && s.frames < 400)
        #expect(s.seconds >= 4.5 && s.seconds < 7)
        #expect(s.fps > 20 && s.fps < 80)
    }

    @Test func rejectedTokenSurfacesAsRPCError() async throws {
        let (stats, _, failure) = try await runStream(seconds: 5, frames: 3, token: "WRONG")
        #expect(failure is RPCError)
        #expect(stats.frames == 0)
    }
}
