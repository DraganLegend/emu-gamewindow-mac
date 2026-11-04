import Testing
@testable import EGWHost

@Suite("Fast frame path: MMAP mapping and Metal display")
struct FastPathTests {
    @Test func regionCoversBothOrientationsPageRounded() {
        #expect(FrameMapping.regionBytes(width: 1280, height: 720) == 1280 * 1280 * 4)
        #expect(FrameMapping.regionBytes(width: 720, height: 1280) == 1280 * 1280 * 4)
        let small = FrameMapping.regionBytes(width: 3, height: 2) ?? 0
        #expect(small == FrameMapping.pageSize)
        #expect(FrameMapping.regionBytes(width: 0, height: 720) == nil)
        #expect(FrameMapping.regionBytes(width: 5000, height: 720) == nil)
        #expect(FrameMapping.avdDisplay(configText: "a=1\nhw.lcd.width=1280\nhw.lcd.height = 720\n")! == (1280, 720))
        #expect(FrameMapping.avdDisplay(configText: "hw.lcd.width=1280\n") == nil)
    }

    @Test func mappingIsPrivateAndRemovedOnce() {
        let r = frameMappingFixture()
        #expect(r.sized && r.privateFile && r.copied && r.removed && r.refusesExisting)
    }

    @Test func metalRotationMatchesInputGeometry() throws {
        let result = try #require(metalRendererMismatches())
        #expect(result.0 == 0)
        #expect(result.1 == "metal-nocopy")   // the mapping is page-aligned, so no per-frame copy
    }

    @Test func prepareFallsBackWithReasons() {
        let r = prepareFastPathFixture()
        #expect(r.ok)
        #expect(r.unknownDisplay == "avd_display_unknown")
        #expect(r.existingFile == "mapping_failed")
    }

    @Test func switchesParse() throws {
        let fast = try GameViewOptions.parse(["game-view", "--auto", "--usb-off-confirmed", "--fast-path", "--seconds", "60"])
        #expect(fast.fastPath)
        #expect(try !GameViewOptions.parse(["game-view", "--auto", "--usb-off-confirmed", "--seconds", "60"]).fastPath)
        #expect(throws: ProbeFailure.self) {
            _ = try GameViewOptions.parse(["game-view", "--auto", "--usb-off-confirmed", "--fast-path", "--fast-path", "--seconds", "60"])
        }
        #expect(LauncherModel.playArguments(minutes: 60, rotate: 0, fastPath: true)?.last == "--fast-path")
        #expect(LauncherModel.playArguments(minutes: 60, rotate: 0)?.contains("--fast-path") == false)
    }

    @Test func presentModeParses() throws {
        let base = ["game-view", "--auto", "--usb-off-confirmed", "--fast-path", "--seconds", "60"]
        #expect(try GameViewOptions.parse(base).presentMode == .nosync3)
        #expect(try GameViewOptions.parse(base + ["--present", "standard"]).presentMode == .standard)
        #expect(try GameViewOptions.parse(base + ["--present", "low"]).presentMode == .low)
        #expect(try GameViewOptions.parse(base + ["--present", "nosync"]).presentMode == .nosync)
        #expect(throws: ProbeFailure.self) { _ = try GameViewOptions.parse(base + ["--present", "fast"]) }
        #expect(throws: ProbeFailure.self) { _ = try GameViewOptions.parse(base + ["--present", "low", "--present", "low"]) }
        #expect(throws: ProbeFailure.self) { _ = try GameViewOptions.parse(base + ["--present"]) }
        // standard keeps the shipped layer settings; the others trade a buffer (and vsync) for latency.
        #expect(PresentMode.standard.drawableCount == 3 && PresentMode.standard.displaySync && !PresentMode.standard.opaque)
        #expect(PresentMode.low.drawableCount == 2 && PresentMode.low.displaySync && PresentMode.low.opaque)
        #expect(PresentMode.nosync.drawableCount == 2 && !PresentMode.nosync.displaySync && PresentMode.nosync.opaque)
        #expect(try GameViewOptions.parse(base + ["--present", "nosync3"]).presentMode == .nosync3)
        #expect(PresentMode.nosync3.drawableCount == 3 && !PresentMode.nosync3.displaySync && PresentMode.nosync3.opaque)
        // Only the no-vsync modes draw on arrival; vsync modes stay on the display link.
        #expect(PresentMode.allCases.filter(\.drawsOnArrival) == [.nosync, .nosync3])
    }
}
