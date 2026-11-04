import Testing
@testable import EGWHost

private let gib = SpacePolicy.gib

@Suite("Space policy and cleaner")
struct SpaceTests {
    // Same vector as scripts/test_space_policy.py.
    @Test func thresholdsFollowAVDGrowth() {
        let p = SpacePolicy(freeBytes: 20 * gib, avdMaxBytes: 24 * gib, avdCurrentBytes: 17 * gib)
        #expect(p.avdRemainingBytes == 7 * gib && p.stopBytes == 15 * gib && p.warnBytes == 22 * gib)
        #expect(p.level == .warn && !p.usesFallback)
        #expect(SpacePolicy(freeBytes: 14 * gib, avdMaxBytes: 24 * gib, avdCurrentBytes: 17 * gib).level == .stop)
        #expect(SpacePolicy(freeBytes: 30 * gib, avdMaxBytes: 24 * gib, avdCurrentBytes: 17 * gib).level == .ok)
        // A full (or slightly over-allocated qcow2) image leaves only the margins.
        let full = SpacePolicy(freeBytes: 10 * gib, avdMaxBytes: 24 * gib, avdCurrentBytes: 25 * gib)
        #expect(full.stopBytes == 8 * gib && full.warnBytes == 15 * gib && full.level == .warn)
        // Unknown AVD numbers (no AVD yet) assume 12 GiB of growth.
        let unknown = SpacePolicy(freeBytes: 25 * gib, avdMaxBytes: nil, avdCurrentBytes: 17 * gib)
        #expect(unknown.usesFallback && unknown.stopBytes == 20 * gib && unknown.warnBytes == 27 * gib && unknown.level == .warn)
    }

    @Test func parsesDataPartitionSize() {
        #expect(SpacePolicy.dataPartitionBytes("a=1\ndisk.dataPartition.size=25769803776\n") == 25_769_803_776)
        #expect(SpacePolicy.dataPartitionBytes("disk.dataPartition.size = 24G") == 24 * gib)
        #expect(SpacePolicy.dataPartitionBytes("disk.dataPartition.size=6144MB") == 6 * gib)
        #expect(SpacePolicy.dataPartitionBytes("disk.dataPartition.size=lots") == nil)
        #expect(SpacePolicy.dataPartitionBytes("disk.dataPartition.size=-5") == nil)
        #expect(SpacePolicy.dataPartitionBytes("disk.cachePartition.size=66MB") == nil)
    }

    @Test func namePatternsAreExact() {
        #expect(SpaceCleaner.runStage("test-20261101-213812-693793") == "test")
        #expect(SpaceCleaner.runStage("build-20261101-213812-693793") == "build")
        #expect(SpaceCleaner.runStage("app-20261101-221235-500517") == "app")
        #expect(SpaceCleaner.runStage("calibration-live-20261029-dda3bf4c") == nil)
        #expect(SpaceCleaner.runStage("test-20261101-213812") == nil)
        #expect(SpaceCleaner.runStage("unknown-20261101-213812-693793") == nil)
        #expect(SpaceCleaner.stamp("play-20261102-190146.json", prefix: "play-", suffix: ".json", micro: false) != nil)
        #expect(SpaceCleaner.stamp("play-latest.json", prefix: "play-", suffix: ".json", micro: false) == nil)
    }

    @Test func cleanerPlansOnlyRegenerableItemsAndKeepsEvidence() {
        let r = cleanerFixture()
        #expect(r.ok)
        #expect(Set(r.planned) == Set([
            ".runtime/state/app/App-build-20261101-221235-500517.app",
            ".runtime/state/test-20261102-000000-000000",
            ".runtime/state/play-20261101-000000.json", ".runtime/state/play-20261101-000000.stderr.txt",
            // Oldest two stamps: day 1 at 00:00 and at 01:00.
            ".runtime/state/play-20261101-010000.json", ".runtime/state/play-20261101-010000.stderr.txt",
            ".runtime/logs/emu-10.log", ".runtime/logs/emu-11.log",
            ".runtime/downloads/commandlinetools.zip",
            ".runtime/state/frames-999999.raw",
        ]))
        // Mentioned in a document: kept.
        #expect(r.evidence == [".runtime/state/test-20261101-000000-000000"])
        #expect(!r.planned.contains { $0.contains("avd") || $0.contains("keymap") || $0.contains("screenshots")
            || $0.contains("checkouts") || $0.hasSuffix("/EmuGameWindow.app") || $0.contains("20200101")
            || $0.hasSuffix("/build-20261101-213428-932673") })
        #expect(r.plannedBuild == [".build/arm64-apple-macosx"])
        // The swapped entry is skipped; everything else goes to the (fake) Trash once.
        #expect(r.skipped == [".runtime/state/app/App-build-20261101-221235-500517.app"])
        #expect(Set(r.trashed) == Set(r.planned).subtracting(r.skipped) && r.trashed.count == r.planned.count - 1)
    }

    @Test func launcherRefusesBelowStopLine() {
        var model = LauncherModel()
        model.space = .stop
        #expect(!model.canStart)
        model.space = .warn
        #expect(model.canStart)
    }
}
