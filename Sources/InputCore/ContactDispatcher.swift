import Foundation

public enum ContactPhase: Equatable, Sendable { case down, move, up }

public struct ContactChange: Equatable, Sendable {
    public let id: Int32
    public let point: PixelPoint
    public let phase: ContactPhase
    public var pressure: Int { phase == .up ? 0 : 512 }
    public init(id: Int32, point: PixelPoint, phase: ContactPhase) {
        self.id = id; self.point = point; self.phase = phase
    }
}

public enum DispatchFault: Equatable, Sendable {
    case overflow, transport, dispatchRejected, sessionChanged, invalidOrder, invalidRequest, tapStopped, permissionLost
}
public enum DispatchOutcome: Equatable, Sendable { case acknowledged, failed, timedOut, notSent }

public struct ContactRequest: Equatable, Sendable {
    public let sequence: UInt64
    public let sessionGeneration: UInt64
    public let change: ContactChange
    public let cleanup: Bool
    public let deadlineMS: Int = 3000
}

/// A value-state outbox: its one owner serializes calls. No tasks or transports
/// are started here. An adapter must enforce deadlineMS and report completion;
/// this type never assumes that a clock tick canceled an in-flight RPC.
public struct ContactDispatcher: Sendable {
    public let sessionGeneration: UInt64
    public private(set) var inFlight: ContactRequest?
    public private(set) var possibleContacts: [Int32: PixelPoint] = [:]
    public private(set) var uncertainIDs: Set<Int32> = []
    public private(set) var fault: DispatchFault?
    public private(set) var draining = false
    private var sessionValid = true
    private var pending: [ContactChange] = []
    private var upAttempted: Set<Int32> = []
    private var nextSequence: UInt64 = 0
    private var lastMoveMS: Int64?
    private var lastPollMS: Int64 = 0
    private var previousPoint: PixelPoint?
    public static let edgeCapacity = 32
    public static let moveIntervalMS: Int64 = 17 // At most 60 move calls/sec.
    private let capacity: Int
    /// Contact IDs this outbox may emit. The original Host keeps two.
    public let allowedIDs: Set<Int32>
    public static let legacyIDs: Set<Int32> = [10001, 10002]

    public init(sessionGeneration: UInt64, edgeCapacity: Int = Self.edgeCapacity,
                allowedIDs: Set<Int32> = Self.legacyIDs) throws {
        guard (1...Self.edgeCapacity).contains(edgeCapacity), !allowedIDs.isEmpty,
              allowedIDs.allSatisfy({ (10001...10016).contains($0) }) else { throw InputCoreError.invalidProfile }
        self.sessionGeneration = sessionGeneration; self.capacity = edgeCapacity; self.allowedIDs = allowedIDs
    }
    public var queuedCount: Int { pending.count }
    public var reservedIDs: Set<Int32> {
        Set(possibleContacts.keys).union(pending.map(\.id)).union(uncertainIDs)
    }
    public var isQuiescent: Bool {
        pending.isEmpty && inFlight == nil && possibleContacts.isEmpty && uncertainIDs.isEmpty
    }

    @discardableResult
    public mutating func enqueue(_ change: ContactChange) -> Bool {
        guard fault == nil, !draining, sessionValid else { return false }
        guard allowedIDs.contains(change.id),
              (0..<4096).contains(change.point.x), (0..<4096).contains(change.point.y) else {
            stop(fault: .invalidRequest); return false
        }
        var planned = Set(possibleContacts.keys).subtracting(upAttempted)
        for item in pending {
            if item.phase == .down { planned.insert(item.id) }
            else if item.phase == .up { planned.remove(item.id) }
        }
        guard change.phase == .down ? !reservedIDs.contains(change.id) : planned.contains(change.id) else {
            stop(fault: .invalidRequest); return false
        }
        if change.phase == .move {
            // Only coalesce within the suffix after the last down/up barrier.
            let start = pending.lastIndex(where: { $0.phase != .move }).map { $0 + 1 } ?? 0
            if let index = pending.indices.reversed().first(where: { $0 >= start && pending[$0].id == change.id }) {
                pending[index] = change; return true
            }
        } else if pending.filter({ $0.phase != .move }).count >= capacity {
            stop(fault: .overflow); return false
        }
        pending.append(change)
        return true
    }

    public mutating func stop(fault reason: DispatchFault? = nil) {
        draining = true
        if fault == nil { fault = reason }
        pending.removeAll(keepingCapacity: true)
    }

    public mutating func invalidateSession() {
        sessionValid = false
        stop(fault: .sessionChanged)
        uncertainIDs.formUnion(possibleContacts.keys)
    }

    public mutating func resume() -> Bool {
        guard isQuiescent, fault == nil, sessionValid else { return false }
        draining = false; lastMoveMS = nil
        return true
    }

    public mutating func next(at milliseconds: Int64) -> ContactRequest? {
        guard milliseconds >= lastPollMS else { stop(fault: .invalidOrder); return nil }
        lastPollMS = milliseconds
        guard inFlight == nil, sessionValid else { return nil }
        let change: ContactChange
        if draining {
            guard let id = possibleContacts.keys.sorted().first(where: { !upAttempted.contains($0) }),
                  let point = possibleContacts[id] else { return nil }
            change = .init(id: id, point: point, phase: .up)
        } else {
            guard let first = pending.first else { return nil }
            if first.phase == .move, let lastMoveMS,
               milliseconds - lastMoveMS < Self.moveIntervalMS { return nil }
            change = pending.removeFirst()
        }
        previousPoint = possibleContacts[change.id]
        if change.phase == .up { upAttempted.insert(change.id) }
        else {
            possibleContacts[change.id] = change.point
            if change.phase == .down { upAttempted.remove(change.id) }
        }
        if change.phase == .move { lastMoveMS = milliseconds }
        guard nextSequence < UInt64.max else { stop(fault: .invalidOrder); return nil }
        nextSequence += 1
        let request = ContactRequest(sequence: nextSequence, sessionGeneration: sessionGeneration,
                                     change: change, cleanup: draining)
        inFlight = request
        return request
    }

    @discardableResult
    public mutating func complete(sequence: UInt64, outcome: DispatchOutcome) -> Bool {
        guard let request = inFlight, request.sequence == sequence else { return false }
        inFlight = nil
        let previous = previousPoint
        previousPoint = nil
        if outcome == .notSent {
            // A prepared ticket is not proof of a network attempt. Restore
            // the pre-call contact state without manufacturing a Guest up.
            switch request.change.phase {
            case .down:
                possibleContacts.removeValue(forKey: request.change.id)
                uncertainIDs.remove(request.change.id)
            case .move:
                if let previous { possibleContacts[request.change.id] = previous }
            case .up:
                if request.cleanup { uncertainIDs.insert(request.change.id) }
                else { upAttempted.remove(request.change.id) }
            }
            stop(fault: .dispatchRejected)
            return true
        }
        guard sessionValid else { uncertainIDs.insert(request.change.id); return true }
        if outcome == .acknowledged {
            if request.change.phase == .up {
                possibleContacts.removeValue(forKey: request.change.id)
                upAttempted.remove(request.change.id)
            }
        } else {
            if request.change.phase == .up { uncertainIDs.insert(request.change.id) }
            stop(fault: .transport)
        }
        return true
    }
}
