import CoreGraphics
import Foundation
import QuartzCore

/// Latest-frame handoff between the receive task and the display link.
/// The receiver never waits
/// for drawing: it replaces the latest frame and goes back to the stream. The
/// display link takes whatever is newest once per screen refresh.
final class FrameMailbox: @unchecked Sendable {
    enum Payload: @unchecked Sendable {
        /// Pixels are in the shared mapping (fast path).
        case mapped
        /// Pixels were decoded off the main thread (gRPC path).
        case image(CGImage)
    }

    struct Frame: @unchecked Sendable {
        let seq: UInt64
        let width: Int
        let height: Int
        let rotation: Int
        let payload: Payload
        /// `CACurrentMediaTime()` when the frame was received.
        let arrival: CFTimeInterval
    }

    private let lock = NSLock()
    private var latest: Frame?
    private var nextSeq: UInt64 = 0
    private var taken: UInt64 = 0
    private(set) var superseded = 0

    /// Stores a new frame; returns true for the very first one (the window
    /// does not exist yet, so the caller must wake the main thread once).
    @discardableResult
    func put(width: Int, height: Int, rotation: Int, payload: Payload, arrival: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        nextSeq += 1
        if let old = latest, old.seq > taken { superseded += 1 }   // replaced before it was shown
        latest = Frame(seq: nextSeq, width: width, height: height, rotation: rotation, payload: payload, arrival: arrival)
        return nextSeq == 1
    }

    /// The newest frame not taken yet, or nil.
    func take() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame = latest, frame.seq > taken else { return nil }
        taken = frame.seq
        return frame
    }

    var supersededCount: Int { lock.lock(); defer { lock.unlock() }; return superseded }
}

/// Per-stage display timings:
///  - wait: received → taken by the display link
///  - present: taken → on screen (Metal presented handler; fast path only)
final class StageStats: @unchecked Sendable {
    static let limit = 50_000
    private let lock = NSLock()
    private var waits: [Double] = []
    private var presents: [Double] = []

    func wait(_ ms: Double) { add(ms, to: \.waits) }
    func present(_ ms: Double) { add(ms, to: \.presents) }

    private func add(_ value: Double, to path: ReferenceWritableKeyPath<StageStats, [Double]>) {
        guard value.isFinite, value >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if self[keyPath: path].count < Self.limit { self[keyPath: path].append(value) }
    }

    struct Summary: Encodable, Equatable, Sendable {
        let samples: Int
        let p50: Double
        let p95: Double
        let max: Double
    }

    static func summarize(_ values: [Double]) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func pick(_ q: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
            return (sorted[index] * 100).rounded() / 100
        }
        return .init(samples: sorted.count, p50: pick(0.5), p95: pick(0.95), max: (sorted.last! * 100).rounded() / 100)
    }

    var waitSummary: Summary? { lock.lock(); defer { lock.unlock() }; return Self.summarize(waits) }
    var presentSummary: Summary? { lock.lock(); defer { lock.unlock() }; return Self.summarize(presents) }
}

/// System thermal pressure (read-only), sampled with the CPU samples.
enum ThermalSampler {
    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    static let order = ["nominal", "fair", "serious", "critical", "unknown"]
    static func worst(_ labels: [String]) -> String? {
        labels.max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
    }
}

/// How the fast path presents Metal frames. `nosync3` (the default) presents
/// without waiting for vsync and draws each frame as soon as it arrives.
enum PresentMode: String, Sendable, CaseIterable {
    /// 3 drawables, presents wait for vsync (the original behaviour).
    case standard
    /// 2 drawables, opaque layer, vsync kept.
    case low
    /// 2 drawables, opaque layer, presents do not wait for vsync (may tear).
    case nosync
    /// Like `nosync` but with 3 drawables, so fewer frames wait or get superseded.
    case nosync3

    var drawableCount: Int { self == .low || self == .nosync ? 2 : 3 }
    var displaySync: Bool { self == .standard || self == .low }
    var opaque: Bool { self != .standard }
    /// Modes that do not wait for vsync draw as soon as a frame arrives instead
    /// of on the next display-link tick (saves the arrival→tick phase wait).
    var drawsOnArrival: Bool { !displaySync }
}
