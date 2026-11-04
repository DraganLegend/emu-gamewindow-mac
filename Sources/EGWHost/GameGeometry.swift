import Foundation
import InputCore

/// How a streamed frame's `rotation` relates to the Guest touch panel. The
/// Emulator returns frames "oriented by the coarse device orientation"; whether
/// sendTouch then expects panel or picture coordinates, and in which direction
/// the turn goes, is not documented. Until a live check settles it this is an
/// explicit, recorded choice, like `--flip-frames`.
enum StreamRotationMap: String, Sendable, CaseIterable {
    /// Picture = panel turned `rotation` quarter turns clockwise.
    case cw
    /// Picture = panel turned `rotation` quarter turns counter-clockwise.
    case ccw
    /// Touch coordinates are the picture's own (no undo).
    case none
}

/// One frame layout: panel (touch space) -> picture (as streamed) -> display
/// (as shown, after the viewer's own rotation). Every point the keymap stores
/// is in panel-normalized space, so a saved keymap survives view rotation.
struct GameGeometry: Equatable, Sendable {
    let pictureWidth: Int
    let pictureHeight: Int
    let streamRotation: Int
    let streamMap: StreamRotationMap
    /// Viewer's choice, quarter turns clockwise applied to the picture.
    let viewTurns: Int

    init?(pictureWidth: Int, pictureHeight: Int, streamRotation: Int, streamMap: StreamRotationMap, viewTurns: Int) {
        guard (1...4096).contains(pictureWidth), (1...4096).contains(pictureHeight),
              (0...3).contains(streamRotation), (0...3).contains(viewTurns) else { return nil }
        self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
        self.streamRotation = streamRotation; self.streamMap = streamMap; self.viewTurns = viewTurns
    }

    /// Clockwise quarter turns from panel to picture.
    var streamTurns: Int {
        switch streamMap {
        case .cw: return streamRotation
        case .ccw: return (4 - streamRotation) % 4
        case .none: return 0
        }
    }
    /// Clockwise quarter turns from panel to display.
    var totalTurns: Int { (streamTurns + viewTurns) % 4 }

    var panelWidth: Int { streamTurns % 2 == 0 ? pictureWidth : pictureHeight }
    var panelHeight: Int { streamTurns % 2 == 0 ? pictureHeight : pictureWidth }
    var displayWidth: Int { viewTurns % 2 == 0 ? pictureWidth : pictureHeight }
    var displayHeight: Int { viewTurns % 2 == 0 ? pictureHeight : pictureWidth }

    /// Turn a normalized point `turns` quarter turns clockwise (top-left origin).
    static func turn(_ x: Double, _ y: Double, clockwise turns: Int) -> (Double, Double) {
        switch ((turns % 4) + 4) % 4 {
        case 1: return (1 - y, x)
        case 2: return (1 - x, 1 - y)
        case 3: return (y, 1 - x)
        default: return (x, y)
        }
    }

    /// Display-normalized (what the viewer clicks) -> panel-normalized (touch space).
    func panel(fromDisplay u: Double, _ v: Double) -> (Double, Double) {
        Self.turn(u, v, clockwise: 4 - totalTurns)
    }

    /// Panel-normalized -> display-normalized, for drawing the keymap.
    func display(fromPanel x: Double, _ y: Double) -> (Double, Double) {
        Self.turn(x, y, clockwise: totalTurns)
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    func displayPoint(_ p: NormalizedPoint) -> NormalizedPoint {
        let (x, y) = display(fromPanel: p.x, p.y); return .init(x: Self.clamp(x), y: Self.clamp(y))
    }
    func panelPoint(_ p: NormalizedPoint) -> NormalizedPoint {
        let (x, y) = panel(fromDisplay: p.x, p.y); return .init(x: Self.clamp(x), y: Self.clamp(y))
    }

    /// Stick key roles are stored as screen directions (W = up as the viewer
    /// sees it); the core moves in panel space. Clockwise order up/right/down/left:
    /// the panel direction i is shown as display direction (i + totalTurns) % 4.
    func panelRoles(_ stick: JoystickBinding) -> JoystickBinding {
        let display = [stick.up, stick.right, stick.down, stick.left]
        let role = { (i: Int) in display[(i + totalTurns) % 4] }
        return .init(center: stick.center, radius: stick.radius, up: role(0), down: role(2), left: role(3), right: role(1))
    }

    /// Stored keymap (panel points, screen roles) -> what the core runs on.
    func coreProfile(_ stored: MappingProfile) throws -> MappingProfile {
        try MappingProfile(bindings: stored.bindings, joystick: stored.joystick.map(panelRoles))
    }

    /// Stored keymap -> editor space (display points, screen roles).
    func displayProfile(_ stored: MappingProfile) throws -> MappingProfile {
        try MappingProfile(
            bindings: stored.bindings.map { .init(keyCode: $0.keyCode, label: $0.label, point: displayPoint($0.point)) },
            joystick: stored.joystick.map { .init(center: displayPoint($0.center), radius: $0.radius,
                                                   up: $0.up, down: $0.down, left: $0.left, right: $0.right) })
    }

    /// Editor space -> stored keymap.
    func storedProfile(fromDisplay edited: MappingProfile) throws -> MappingProfile {
        try MappingProfile(
            bindings: edited.bindings.map { .init(keyCode: $0.keyCode, label: $0.label, point: panelPoint($0.point)) },
            joystick: edited.joystick.map { .init(center: panelPoint($0.center), radius: $0.radius,
                                                   up: $0.up, down: $0.down, left: $0.left, right: $0.right) })
    }

}
