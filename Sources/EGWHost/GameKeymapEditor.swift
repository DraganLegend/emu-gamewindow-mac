import InputCore

enum KeyLabel {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static func name(_ code: UInt16) -> String { names[code] ?? "Key\(code)" }
}

/// Click a place on the picture, then press the key to bind it. Pure state
/// machine: the window feeds it view-space clicks and key codes.
struct KeymapEditor: Equatable {
    enum Reason: Equatable { case duplicate, full, reserved }
    enum Outcome: Equatable {
        case none, bound(Int), rebound(Int), removed, rejected(Reason), cancelled, exit
        case joystickPlaced, joystickRemoved, joystickResized
    }
    /// Default stick keys: W up, S down, A left, D right.
    static let stickKeys = (up: UInt16(13), down: UInt16(1), left: UInt16(0), right: UInt16(2))
    static let defaultStickRadius = 0.12

    static let hitRadius = 22.0
    static let escape: UInt16 = 53, delete: UInt16 = 51, forwardDelete: UInt16 = 117

    private(set) var bindings: [SkillBinding]
    private(set) var pending: NormalizedPoint?
    private(set) var selected: Int?
    private(set) var joystick: JoystickBinding?
    private(set) var joystickSelected = false
    let viewWidth: Double
    let viewHeight: Double

    init(bindings: [SkillBinding], joystick: JoystickBinding? = nil, viewWidth: Double, viewHeight: Double) {
        self.bindings = bindings; self.joystick = joystick; self.viewWidth = viewWidth; self.viewHeight = viewHeight
    }

    private var usedCodes: Set<UInt16> { Set(bindings.map(\.keyCode) + (joystick?.keys ?? [])) }

    private func hitsStick(_ x: Double, _ y: Double) -> Bool {
        guard let stick = joystick else { return false }
        let dx = stick.center.x * viewWidth - x, dy = stick.center.y * viewHeight - y
        return (dx * dx + dy * dy).squareRoot() <= Self.hitRadius
    }

    /// Put the stick at the chosen place with W/A/S/D. Replaces an existing stick.
    mutating func placeJoystick() -> Outcome {
        guard let point = pending else { return .none }
        let keys = Self.stickKeys
        let codes: Set<UInt16> = [keys.up, keys.down, keys.left, keys.right]
        guard bindings.allSatisfy({ !codes.contains($0.keyCode) }) else { return .rejected(.duplicate) }
        joystick = .init(center: point, radius: joystick?.radius ?? Self.defaultStickRadius,
                         up: keys.up, down: keys.down, left: keys.left, right: keys.right)
        pending = nil; selected = nil; joystickSelected = false
        return .joystickPlaced
    }

    mutating func resizeJoystick(by delta: Double) -> Outcome {
        guard let stick = joystick, delta.isFinite else { return .none }
        joystick = stick.withRadius(stick.radius + delta)
        return .joystickResized
    }

    private func hit(_ x: Double, _ y: Double) -> Int? {
        bindings.indices.map { index -> (Int, Double) in
            let dx = bindings[index].point.x * viewWidth - x, dy = bindings[index].point.y * viewHeight - y
            return (index, (dx * dx + dy * dy).squareRoot())
        }.filter { $0.1 <= Self.hitRadius }.min { $0.1 < $1.1 }?.0
    }

    mutating func click(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, viewWidth > 0, viewHeight > 0 else { return }
        if let index = hit(x, y) { selected = index; pending = nil; joystickSelected = false; return }
        if hitsStick(x, y) { joystickSelected = true; selected = nil; pending = nil; return }
        selected = nil; joystickSelected = false
        pending = .init(x: min(1, max(0, x / viewWidth)), y: min(1, max(0, y / viewHeight)))
    }

    /// Drag the selected point (or the stick, or the pending place) to a new spot.
    mutating func drag(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, viewWidth > 0, viewHeight > 0 else { return }
        let point = NormalizedPoint(x: min(1, max(0, x / viewWidth)), y: min(1, max(0, y / viewHeight)))
        if let index = selected {
            bindings[index] = .init(keyCode: bindings[index].keyCode, label: bindings[index].label, point: point)
        } else if joystickSelected, let stick = joystick {
            joystick = .init(center: point, radius: stick.radius, up: stick.up, down: stick.down, left: stick.left, right: stick.right)
        } else if pending != nil {
            pending = point
        }
    }

    mutating func key(_ code: UInt16) -> Outcome {
        if code == Self.escape {
            guard pending != nil || selected != nil || joystickSelected else { return .exit }
            pending = nil; selected = nil; joystickSelected = false; return .cancelled
        }
        if code == Self.delete || code == Self.forwardDelete {
            if joystickSelected { joystick = nil; joystickSelected = false; return .joystickRemoved }
            guard let index = selected else { return .none }
            bindings.remove(at: index); selected = nil; return .removed
        }
        // Modifier positions and codes outside the profile's range cannot be bound.
        guard code < 128, !(54...63).contains(code) else { return .rejected(.reserved) }
        if let point = pending {
            guard !usedCodes.contains(code) else { return .rejected(.duplicate) }
            guard bindings.count < MappingProfile.maximumBindings else { return .rejected(.full) }
            bindings.append(.init(keyCode: code, label: KeyLabel.name(code), point: point))
            pending = nil; return .bound(bindings.count - 1)
        }
        if let index = selected {
            guard !bindings.indices.contains(where: { $0 != index && bindings[$0].keyCode == code }),
                  !(joystick?.keys.contains(code) ?? false) else {
                return .rejected(.duplicate)
            }
            bindings[index] = .init(keyCode: code, label: KeyLabel.name(code), point: bindings[index].point)
            return .rebound(index)
        }
        return .none
    }

    func profile() throws -> MappingProfile { try MappingProfile(bindings: bindings, joystick: joystick) }
}
