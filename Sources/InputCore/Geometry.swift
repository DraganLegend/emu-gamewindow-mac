import Foundation

public enum InputCoreError: Error, Equatable, Sendable {
    case invalidProfile, invalidGeometry
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public struct HostPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    var finite: Bool { x.isFinite && y.isFinite }
}

public struct PixelPoint: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct HostRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var valid: Bool {
        [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite)
            && width > 0 && height > 0 && x + width > x && y + height > y
    }
    public func contains(_ point: HostPoint) -> Bool {
        valid && point.finite && point.x >= x && point.x < x + width
            && point.y >= y && point.y < y + height
    }
    func contains(_ rect: HostRect) -> Bool {
        valid && rect.valid && rect.x >= x && rect.y >= y
            && rect.x + rect.width <= x + width && rect.y + rect.height <= y + height
    }
}

/// Geometry values are supplied by a future adapter, never inspected here.
public struct InputCalibration: Equatable, Sendable {
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let rotation: Int
    public let displayRect: HostRect
    public let interactionRect: HostRect

    public init(generation: UInt64, width: Int, height: Int, rotation: Int,
                displayRect: HostRect, interactionRect: HostRect) throws {
        guard (1...4096).contains(width), (1...4096).contains(height),
              (0...3).contains(rotation), displayRect.contains(interactionRect) else {
            throw InputCoreError.invalidGeometry
        }
        self.generation = generation; self.width = width; self.height = height
        self.rotation = rotation; self.displayRect = displayRect; self.interactionRect = interactionRect
    }

    public func pixels(_ point: NormalizedPoint) throws -> PixelPoint {
        guard point.valid else { throw InputCoreError.invalidGeometry }
        return .init(x: Int(floor(point.x * Double(width - 1))),
                     y: Int(floor(point.y * Double(height - 1))))
    }

    public func pixels(_ point: HostPoint, clamp: Bool) throws -> PixelPoint {
        guard point.finite else { throw InputCoreError.invalidGeometry }
        let u = (point.x - displayRect.x) / displayRect.width
        let v = (point.y - displayRect.y) / displayRect.height
        guard u.isFinite && v.isFinite else { throw InputCoreError.invalidGeometry }
        return try pixels(.init(x: clamp ? min(1, max(0, u)) : u,
                                y: clamp ? min(1, max(0, v)) : v))
    }
}
