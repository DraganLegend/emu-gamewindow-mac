import Foundation

public struct SkillBinding: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let label: String
    public let point: NormalizedPoint
    public init(keyCode: UInt16, label: String, point: NormalizedPoint) {
        self.keyCode = keyCode; self.label = label; self.point = point
    }
}

/// Four keys drive one virtual-stick contact: it goes down at `center` and
/// moves toward the held direction by `radius` (a fraction of the shorter
/// Guest side). Opposite keys cancel; the contact lifts when no key is held.
public struct JoystickBinding: Codable, Equatable, Sendable {
    public let center: NormalizedPoint
    public let radius: Double
    public let up: UInt16
    public let down: UInt16
    public let left: UInt16
    public let right: UInt16
    public static let radiusRange = 0.02...0.5

    public init(center: NormalizedPoint, radius: Double, up: UInt16, down: UInt16, left: UInt16, right: UInt16) {
        self.center = center; self.radius = radius
        self.up = up; self.down = down; self.left = left; self.right = right
    }

    public var keys: [UInt16] { [up, down, left, right] }
    var valid: Bool { center.valid && radius.isFinite && Self.radiusRange.contains(radius) }

    public func withRadius(_ value: Double) -> JoystickBinding {
        .init(center: center, radius: min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, value)),
              up: up, down: down, left: left, right: right)
    }
}

public struct MappingProfile: Codable, Equatable, Sendable {
    public let schema: Int
    public let bindings: [SkillBinding]
    public let joystick: JoystickBinding?
    // Legacy Host: two contact slots. The own game window raises this through
    // ContactLimits; the profile only bounds how many keys can be bound.
    public static let maximumContacts = 2
    public static let maximumBindings = 8

    /// Schema 1 has no joystick; schema 2 is exactly "schema 1 plus a joystick".
    public init(schema: Int? = nil, bindings: [SkillBinding], joystick: JoystickBinding? = nil) throws {
        let schema = schema ?? (joystick == nil ? 1 : 2)
        // Physical modifier positions are not first-slice mapping triggers.
        let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        let codes = bindings.map(\.keyCode) + (joystick?.keys ?? [])
        guard schema == (joystick == nil ? 1 : 2), (0...Self.maximumBindings).contains(bindings.count),
              Set(codes).count == codes.count,
              codes.allSatisfy({ $0 < 128 && !modifiers.contains($0) }),
              bindings.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 64 && $0.point.valid }),
              joystick?.valid ?? true else {
            throw InputCoreError.invalidProfile
        }
        self.schema = schema; self.bindings = bindings; self.joystick = joystick
    }

    private enum CodingKeys: CodingKey { case schema, bindings, joystick }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schema: values.decode(Int.self, forKey: .schema),
                      bindings: values.decode([SkillBinding].self, forKey: .bindings),
                      joystick: values.decodeIfPresent(JoystickBinding.self, forKey: .joystick))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(bindings, forKey: .bindings)
        try values.encodeIfPresent(joystick, forKey: .joystick)
    }
}
