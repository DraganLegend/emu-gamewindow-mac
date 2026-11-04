import Testing
@testable import EGWHost

@Suite("Receive/display decoupling and stage timings")
struct FrameSchedulingTests {
    @Test func mailboxKeepsOnlyTheNewestFrame() {
        let box = FrameMailbox()
        #expect(box.take() == nil)
        #expect(box.put(width: 1280, height: 720, rotation: 0, payload: .mapped, arrival: 1.0))   // first
        #expect(!box.put(width: 1280, height: 720, rotation: 0, payload: .mapped, arrival: 1.016))
        #expect(!box.put(width: 1280, height: 720, rotation: 1, payload: .mapped, arrival: 1.033))
        let frame = box.take()
        #expect(frame?.seq == 3 && frame?.rotation == 1 && frame?.arrival == 1.033)
        #expect(box.supersededCount == 2)        // frames 1 and 2 were never shown
        #expect(box.take() == nil)               // nothing new
        box.put(width: 1280, height: 720, rotation: 0, payload: .mapped, arrival: 1.05)
        #expect(box.supersededCount == 2)        // the taken frame does not count as replaced
        #expect(box.take()?.seq == 4)
    }

    @Test func stageStatsSummaries() {
        let stats = StageStats()
        #expect(stats.waitSummary == nil && stats.presentSummary == nil)
        for ms in [1.0, 2.0, 3.0, 4.0, 100.0] { stats.wait(ms) }
        stats.wait(-1); stats.wait(.nan)         // ignored
        let s = stats.waitSummary
        #expect(s?.samples == 5 && s?.p50 == 3 && s?.p95 == 100 && s?.max == 100)
        stats.present(8.333)
        #expect(stats.presentSummary == .init(samples: 1, p50: 8.33, p95: 8.33, max: 8.33))
    }

    @Test func thermalWorst() {
        #expect(ThermalSampler.worst([]) == nil)
        #expect(ThermalSampler.worst(["nominal", "serious", "fair"]) == "serious")
        #expect(ThermalSampler.label(.critical) == "critical")
    }
}
