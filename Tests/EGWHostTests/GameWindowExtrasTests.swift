import InputCore
import Testing
@testable import EGWHost

@Suite("Game window: layout, buttons, screenshot, profiles")
struct GameWindowExtrasTests {
    @Test func pictureFitsAndCenters() {
        let wide = GameLayout.fit(displayWidth: 1280, displayHeight: 720, in: .init(width: 1000, height: 1000))
        #expect(wide.width == 1000 && wide.height == 562 && wide.minX == 0 && wide.minY == 219)
        let tall = GameLayout.fit(displayWidth: 1280, displayHeight: 720, in: .init(width: 2000, height: 720))
        #expect(tall.width == 1280 && tall.height == 720 && tall.minX == 360 && tall.minY == 0)
        #expect(GameLayout.fit(displayWidth: 0, displayHeight: 720, in: .init(width: 100, height: 100)) == .zero)
        #expect(GameLayout.fit(displayWidth: 1280, displayHeight: 720, in: .zero) == .zero)
    }

    @Test func androidKeysUseDocumentedNamesAndEvdev() {
        #expect(AndroidKey.back.event.key == "GoBack" && AndroidKey.back.event.eventType == .keypress)
        #expect(AndroidKey.home.event.key == "GoHome")
        #expect(AndroidKey.recents.event.key == "AppSwitch")
        #expect(AndroidKey.volumeUp.event.codeType == .evdev && AndroidKey.volumeUp.event.keyCode == 115)
        #expect(AndroidKey.volumeDown.event.keyCode == 114 && AndroidKey.volumeDown.event.eventType == .keypress)
    }

    @Test func screenshotsArePrivateNewPNGs() {
        let (named, privateFiles, noOverwrite, png) = screenshotFixture()
        #expect(named && privateFiles && noOverwrite && png)
    }

    @Test func editorDragsSelectedPointStickAndPending() {
        var editor = KeymapEditor(bindings: [.init(keyCode: 14, label: "E", point: .init(x: 0.5, y: 0.5))],
                                  viewWidth: 640, viewHeight: 360)
        editor.click(x: 320, y: 180)                 // select E
        editor.drag(x: 64, y: 36)
        #expect(editor.bindings[0].point == NormalizedPoint(x: 0.1, y: 0.1))
        editor.drag(x: -50, y: 9999)                 // clamped
        #expect(editor.bindings[0].point == NormalizedPoint(x: 0, y: 1))
        _ = editor.key(KeymapEditor.escape)
        editor.click(x: 320, y: 180); _ = editor.placeJoystick()
        editor.click(x: 320, y: 180)                 // select the stick
        editor.drag(x: 160, y: 90)
        #expect(editor.joystick?.center == NormalizedPoint(x: 0.25, y: 0.25))
        _ = editor.key(KeymapEditor.escape)
        editor.click(x: 600, y: 300)                 // pending
        editor.drag(x: 480, y: 270)
        #expect(editor.pending == NormalizedPoint(x: 0.75, y: 0.75))
    }

    @Test func namedProfilesRoundTrip() {
        let r = profileFixture()
        #expect(r.names == ["boss", "主線"] && r.roundTrip && r.missingFails && r.badNameFails)
        #expect(GameKeymapStore.validProfileName("  Boss 戰 ") == "Boss 戰")
        for bad in ["", "   ", ".hidden", "a/b", "a\\b", "a:b", String(repeating: "x", count: 33)] {
            #expect(GameKeymapStore.validProfileName(bad) == nil)
        }
    }
}
