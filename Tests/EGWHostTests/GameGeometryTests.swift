import InputCore
import Testing
@testable import EGWHost

private func geometry(_ w: Int, _ h: Int, stream: Int = 0, map: StreamRotationMap = .cw, view: Int = 0) throws -> GameGeometry {
    try #require(GameGeometry(pictureWidth: w, pictureHeight: h, streamRotation: stream, streamMap: map, viewTurns: view))
}

private func flush(_ model: inout GameInputModel, from start: Int64) -> [ContactRequest] {
    var out: [ContactRequest] = []
    var now = start
    for _ in 0..<40 {
        now += 20
        if let request = model.nextRequest(at: now) {
            out.append(request); model.complete(sequence: request.sequence, outcome: .acknowledged)
        }
    }
    return out
}

@Suite("Game geometry, rotation and quit options", .timeLimit(.minutes(1)))
struct GameGeometryTests {
    @Test func rendererAndInputMathAgreeForEveryTurn() {
        #expect(rendererGeometryMismatches() == 0)
    }

    @Test func turnsRoundTripAndSizesSwap() throws {
        for turns in 0..<4 {
            let g = try geometry(720, 1280, view: turns)
            let (u, v) = g.display(fromPanel: 0.2, 0.7)
            let (x, y) = g.panel(fromDisplay: u, v)
            #expect(abs(x - 0.2) < 1e-12 && abs(y - 0.7) < 1e-12)
            #expect((g.displayWidth, g.displayHeight) == (turns % 2 == 0 ? (720, 1280) : (1280, 720)))
            #expect((g.panelWidth, g.panelHeight) == (720, 1280))
        }
        // Clockwise: the panel's top-left corner shows at the top-right.
        let (u, v) = try geometry(720, 1280, view: 1).display(fromPanel: 0, 0)
        #expect(u == 1 && v == 0)
    }

    @Test func streamRotationMapsChooseThePanel() throws {
        // A landscape picture with rotation 1 comes from a portrait panel unless the map is `none`.
        #expect(try geometry(1280, 720, stream: 1, map: .cw).panelWidth == 720)
        #expect(try geometry(1280, 720, stream: 1, map: .ccw).streamTurns == 3)
        let none = try geometry(1280, 720, stream: 1, map: .none)
        #expect(none.streamTurns == 0 && none.panelWidth == 1280)
        #expect(GameGeometry(pictureWidth: 0, pictureHeight: 720, streamRotation: 0, streamMap: .cw, viewTurns: 0) == nil)
        #expect(GameGeometry(pictureWidth: 720, pictureHeight: 1280, streamRotation: 4, streamMap: .cw, viewTurns: 0) == nil)
    }

    @Test func rotatedViewClickHitsTheRightPanelPixel() throws {
        // Sideways game in a portrait stream, viewer turns the view 90° clockwise:
        // the window is 640x360 and its top-right corner is the panel's top-left.
        let g = try geometry(720, 1280, view: 1)
        var model = try GameInputModel(profile: MappingProfile(bindings: []), geometry: g, viewWidth: 640, viewHeight: 360)
        model.setFocused(true, at: 1); model.tick(at: 2)
        model.send(.leftDown(HostPoint(x: 639.9, y: 0.1)), at: 10)
        model.send(.leftUp(HostPoint(x: 639.9, y: 0.1)), at: 20)
        let requests = flush(&model, from: 20)
        #expect(requests.count == 2)
        let point = try #require(requests.first?.change.point)
        #expect(point.x <= 1 && point.y <= 1)
    }

    @Test func stickRolesFollowTheScreen() throws {
        let stick = JoystickBinding(center: .init(x: 0.5, y: 0.5), radius: 0.1, up: 13, down: 1, left: 0, right: 2)
        // No turn: unchanged.
        #expect(try geometry(720, 1280).panelRoles(stick) == stick)
        // View turned 90° clockwise: screen-up is panel-left, so W drives panel left.
        let turned = try geometry(720, 1280, view: 1).panelRoles(stick)
        #expect(turned.left == 13 && turned.up == 2 && turned.right == 1 && turned.down == 0)
        // Stored keymap round-trips through editor space.
        let g = try geometry(720, 1280, view: 3)
        let stored = try MappingProfile(bindings: [.init(keyCode: 14, label: "E", point: .init(x: 0.25, y: 0.5))], joystick: stick)
        let back = try g.storedProfile(fromDisplay: g.displayProfile(stored))
        #expect(abs(back.bindings[0].point.x - 0.25) < 1e-12 && abs(back.bindings[0].point.y - 0.5) < 1e-12)
        #expect(back.joystick?.up == 13)
    }

    @Test func pressingWInARotatedViewMovesUpOnScreen() throws {
        let g = try geometry(720, 1280, view: 1)
        let stick = JoystickBinding(center: .init(x: 0.5, y: 0.5), radius: 0.1, up: 13, down: 1, left: 0, right: 2)
        var model = try GameInputModel(profile: MappingProfile(bindings: [], joystick: stick), geometry: g,
                                       viewWidth: 640, viewHeight: 360)
        model.setFocused(true, at: 1); model.tick(at: 2)
        model.send(.keyDown(13, autorepeat: false), at: 10)
        let requests = flush(&model, from: 10)
        let down = try #require(requests.first?.change.point), move = try #require(requests.last?.change.point)
        // Screen-up through a 90° clockwise view is panel-left (smaller x, same y).
        #expect(move.x < down.x && move.y == down.y)
    }

    @Test func parsesRotationOptions() throws {
        let ok = try GameViewOptions.parse(["game-view", "--session", "/s.json", "--seconds", "60",
                                            "--rotate", "270", "--stream-rotation-map", "none"])
        #expect(ok.viewTurns == 3 && ok.streamMap == .none)
        let plain = try GameViewOptions.parse(["game-view", "--session", "/s.json", "--seconds", "60"])
        #expect(plain.viewTurns == 0 && plain.streamMap == .cw)
        for args in [["--rotate", "45"], ["--stream-rotation-map", "left"], ["--rotate", "90", "--rotate", "90"]] {
            #expect(throws: ProbeFailure.self) {
                _ = try GameViewOptions.parse(["game-view", "--session", "/s.json", "--seconds", "60"] + args)
            }
        }
    }

    @Test func editorPlacesResizesAndRemovesStick() {
        var editor = KeymapEditor(bindings: [], viewWidth: 640, viewHeight: 360)
        #expect(editor.placeJoystick() == .none)
        editor.click(x: 100, y: 200)
        #expect(editor.placeJoystick() == .joystickPlaced)
        #expect(editor.joystick?.radius == KeymapEditor.defaultStickRadius)
        #expect(editor.resizeJoystick(by: 0.02) == .joystickResized)
        // W is taken by the stick.
        editor.click(x: 500, y: 100)
        #expect(editor.key(13) == .rejected(.duplicate))
        #expect(editor.key(14) == .bound(0))
        editor.click(x: 100, y: 200)
        #expect(editor.joystickSelected)
        #expect(editor.key(KeymapEditor.delete) == .joystickRemoved)
        #expect(editor.joystick == nil)
        #expect((try? editor.profile())?.schema == 1)
        // A skill on W blocks placing the stick.
        var blocked = KeymapEditor(bindings: [.init(keyCode: 13, label: "W", point: .init(x: 0.1, y: 0.1))],
                                   viewWidth: 640, viewHeight: 360)
        blocked.click(x: 300, y: 300)
        #expect(blocked.placeJoystick() == .rejected(.duplicate))
    }
}
