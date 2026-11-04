import Foundation

/// `joystick` owns the virtual-stick contact; its physical keys stay `.key`.
public enum InputSource: Hashable, Sendable { case key(UInt16), left, right, joystick }

/// How many contacts may exist and what a too-long hold does.
public struct ContactLimits: Equatable, Sendable {
    public enum HoldPolicy: Equatable, Sendable {
        /// Original Host: any contact held this long stops the whole mapping.
        case stopAll(ms: Int64)
        /// Game window: only that contact is lifted; the mapping keeps running.
        case releaseContact(ms: Int64)
    }
    public let contactIDs: [Int32]
    public let hold: HoldPolicy

    public init(contactIDs: [Int32], hold: HoldPolicy) throws {
        guard !contactIDs.isEmpty, Set(contactIDs).count == contactIDs.count,
              contactIDs.allSatisfy({ (10001...10016).contains($0) }) else { throw InputCoreError.invalidProfile }
        switch hold {
        case .stopAll(let ms), .releaseContact(let ms): guard ms >= 1000 else { throw InputCoreError.invalidProfile }
        }
        self.contactIDs = contactIDs; self.hold = hold
    }

    public static let legacy = try! ContactLimits(contactIDs: [10001, 10002], hold: .stopAll(ms: InputReducer.maximumHoldMS))
    /// Mouse + stick + three skills at once; a 5-minute hold lifts only that contact.
    public static let game = try! ContactLimits(contactIDs: [10001, 10002, 10003, 10004, 10005],
                                                hold: .releaseContact(ms: 300_000))
}
public enum MappingState: Equatable, Sendable { case disabled, ready, active, draining, faulted }
public enum EventDisposition: Equatable, Sendable { case pass, consume }
public enum InputReason: Equatable, Sendable {
    case contactLimit, notReady, invalidGeometry, stopped, fault
}
public struct RoutingDecision: Equatable, Sendable {
    public let disposition: EventDisposition
    public let reason: InputReason?
}

public struct PhysicalSnapshot: Equatable, Sendable {
    public let keys: Set<UInt16>
    public let left: Bool
    public let right: Bool
    public init(keys: Set<UInt16> = [], left: Bool = false, right: Bool = false) {
        self.keys = keys; self.left = left; self.right = right
    }
}

public struct InputContext: Equatable, Sendable {
    public var targetVerified: Bool
    public var focused: Bool
    public var calibrationGeneration: UInt64
    public var sessionGeneration: UInt64
    public var permissionAvailable: Bool
    public var systemShortcutActive: Bool
    public init(targetVerified: Bool = false, focused: Bool = false,
                calibrationGeneration: UInt64, sessionGeneration: UInt64,
                permissionAvailable: Bool = false, systemShortcutActive: Bool = false) {
        self.targetVerified = targetVerified; self.focused = focused
        self.calibrationGeneration = calibrationGeneration; self.sessionGeneration = sessionGeneration
        self.permissionAvailable = permissionAvailable; self.systemShortcutActive = systemShortcutActive
    }
}

public enum InputAction: Equatable, Sendable {
    case enable(PhysicalSnapshot), disable, cancel, tick, tapStopped, permissionLost, systemShortcut
    case keyDown(UInt16, autorepeat: Bool), keyUp(UInt16)
    case leftDown(HostPoint), leftMove(HostPoint), leftUp(HostPoint)
    case rightDown, rightUp, scroll
}

public struct InputEnvelope: Equatable, Sendable {
    public let sequence: UInt64
    public let milliseconds: Int64
    public let action: InputAction
    public init(sequence: UInt64, milliseconds: Int64, action: InputAction) {
        self.sequence = sequence; self.milliseconds = milliseconds; self.action = action
    }
}

public struct OwnedContact: Equatable, Sendable {
    public let id: Int32
    public var point: PixelPoint
    public let startedMS: Int64
}

/// Pure synchronous state transitions. No event taps, text, files, sockets or
/// Runtime inspection. A future adapter supplies validated context snapshots.
public struct InputReducer: Sendable {
    public let profile: MappingProfile
    public let calibration: InputCalibration
    public private(set) var state: MappingState = .disabled
    public private(set) var generation: UInt64 = 0
    public private(set) var contacts: [InputSource: OwnedContact] = [:]
    public private(set) var captured: Set<InputSource> = []
    public private(set) var physicalDown: Set<InputSource> = []
    public private(set) var dispatcher: ContactDispatcher
    public static let maximumHoldMS: Int64 = 10_000
    public let limits: ContactLimits
    /// Direction keys the stick currently treats as held (a subset of `captured`).
    public var joystickHeld: Set<UInt16> {
        guard let stick = profile.joystick else { return [] }
        return Set(stick.keys.filter { captured.contains(.key($0)) })
    }
    private var wantsEnabled = false
    private var lastSequence: UInt64 = 0
    private var lastEventMS: Int64 = 0

    public init(profile: MappingProfile, calibration: InputCalibration, sessionGeneration: UInt64,
                queueEdgeCapacity: Int = ContactDispatcher.edgeCapacity, limits: ContactLimits = .legacy) throws {
        self.profile = profile; self.calibration = calibration; self.limits = limits
        self.dispatcher = try .init(sessionGeneration: sessionGeneration, edgeCapacity: queueEdgeCapacity,
                                    allowedIDs: Set(limits.contactIDs))
    }

    private func isMappedKey(_ code: UInt16) -> Bool {
        profile.bindings.contains(where: { $0.keyCode == code }) || (profile.joystick?.keys.contains(code) ?? false)
    }

    private func eligible(_ context: InputContext) -> Bool {
        context.targetVerified && context.focused && context.permissionAvailable
            && !context.systemShortcutActive && context.calibrationGeneration == calibration.generation
            && context.sessionGeneration == dispatcher.sessionGeneration
    }

    private mutating func stop(fault: DispatchFault? = nil) {
        wantsEnabled = false
        if generation < UInt64.max { generation += 1 }
        contacts.removeAll(keepingCapacity: true)
        dispatcher.stop(fault: fault)
        state = dispatcher.fault == nil ? .draining : .faulted
    }

    private mutating func settle(_ context: InputContext) {
        if dispatcher.fault != nil {
            if state != .faulted && generation < UInt64.max { generation += 1 }
            contacts.removeAll(keepingCapacity: true); wantsEnabled = false; state = .faulted
        } else if state == .draining && dispatcher.isQuiescent && captured.isEmpty && physicalDown.isEmpty {
            state = .disabled
        } else if state == .ready && wantsEnabled && eligible(context)
                    && physicalDown.isEmpty && captured.isEmpty && dispatcher.resume() {
            state = .active
        }
    }

    private mutating func checkHold(at now: Int64) {
        switch limits.hold {
        case .stopAll(let limit):
            if contacts.values.contains(where: { now >= $0.startedMS && now - $0.startedMS >= limit }) { stop() }
        case .releaseContact(let limit):
            // Lift only the expired contact. Its physical source stays captured,
            // so the later key/mouse up is consumed and nothing re-presses by itself.
            for (source, contact) in contacts where now >= contact.startedMS && now - contact.startedMS >= limit {
                contacts.removeValue(forKey: source)
                if state == .active, !dispatcher.enqueue(.init(id: contact.id, point: contact.point, phase: .up)) { stop() }
            }
        }
    }

    private mutating func refresh(_ context: InputContext) {
        if context.sessionGeneration != dispatcher.sessionGeneration {
            dispatcher.invalidateSession(); stop(fault: .sessionChanged)
        } else if state == .active && !eligible(context) {
            stop(fault: context.permissionAvailable ? nil : .permissionLost)
        }
    }

    private func source(_ action: InputAction) -> InputSource? {
        switch action {
        case .keyDown(let code, _), .keyUp(let code):
            return isMappedKey(code) ? .key(code) : nil
        case .leftDown, .leftMove, .leftUp: return .left
        case .rightDown, .rightUp: return .right
        default: return nil
        }
    }

    private mutating func updatePhysical(_ action: InputAction) {
        guard let source = source(action) else { return }
        switch action {
        case .keyDown, .leftDown, .rightDown: physicalDown.insert(source)
        case .keyUp, .leftUp, .rightUp: physicalDown.remove(source)
        default: break
        }
    }

    private mutating func press(_ source: InputSource, point: PixelPoint, at now: Int64) -> RoutingDecision {
        captured.insert(source)
        let used = dispatcher.reservedIDs.union(contacts.values.map(\.id))
        guard let id = limits.contactIDs.first(where: { !used.contains($0) }) else {
            return .init(disposition: .consume, reason: .contactLimit)
        }
        contacts[source] = .init(id: id, point: point, startedMS: now)
        if !dispatcher.enqueue(.init(id: id, point: point, phase: .down)) { stop() }
        return .init(disposition: .consume, reason: dispatcher.fault == nil ? nil : .fault)
    }

    private mutating func release(_ source: InputSource, point: PixelPoint? = nil) -> RoutingDecision {
        guard captured.remove(source) != nil else { return .init(disposition: .pass, reason: nil) }
        if let contact = contacts.removeValue(forKey: source), state == .active {
            if !dispatcher.enqueue(.init(id: contact.id, point: point ?? contact.point, phase: .up)) { stop() }
        }
        return .init(disposition: .consume, reason: nil)
    }

    /// Pixel target for the held direction keys, or nil when none is held.
    /// Opposite keys cancel; a cancelled direction rests at the center.
    private func joystickTarget() -> PixelPoint? {
        guard let stick = profile.joystick, let center = try? calibration.pixels(stick.center) else { return nil }
        let held = joystickHeld
        guard !held.isEmpty else { return nil }
        var dx = 0.0, dy = 0.0
        if held.contains(stick.left) { dx -= 1 }
        if held.contains(stick.right) { dx += 1 }
        if held.contains(stick.up) { dy -= 1 }
        if held.contains(stick.down) { dy += 1 }
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return center }
        let reach = stick.radius * Double(min(calibration.width, calibration.height))
        let x = Double(center.x) + dx / length * reach, y = Double(center.y) + dy / length * reach
        return .init(x: Int(min(Double(calibration.width - 1), max(0, x.rounded()))),
                     y: Int(min(Double(calibration.height - 1), max(0, y.rounded()))))
    }

    /// Brings the stick contact in line with the held keys: down at the
    /// center then a move, a move on direction change, an up when released.
    private mutating func updateJoystick(at now: Int64) -> RoutingDecision {
        guard state == .active else { return .init(disposition: .consume, reason: .stopped) }
        let target = joystickTarget()
        if var contact = contacts[.joystick] {
            if let target {
                if target != contact.point {
                    contact.point = target; contacts[.joystick] = contact
                    if !dispatcher.enqueue(.init(id: contact.id, point: target, phase: .move)) { stop() }
                }
            } else {
                contacts.removeValue(forKey: .joystick)
                if !dispatcher.enqueue(.init(id: contact.id, point: contact.point, phase: .up)) { stop() }
            }
        } else if let target, let stick = profile.joystick, let center = try? calibration.pixels(stick.center) {
            let used = dispatcher.reservedIDs.union(contacts.values.map(\.id))
            guard let id = limits.contactIDs.first(where: { !used.contains($0) }) else {
                return .init(disposition: .consume, reason: .contactLimit)
            }
            contacts[.joystick] = .init(id: id, point: target, startedMS: now)
            if !dispatcher.enqueue(.init(id: id, point: center, phase: .down)) { stop() }
            else if target != center, !dispatcher.enqueue(.init(id: id, point: target, phase: .move)) { stop() }
        }
        return .init(disposition: .consume, reason: dispatcher.fault == nil ? nil : .fault)
    }

    private mutating func unsupported(_ context: InputContext, source: InputSource? = nil) -> RoutingDecision {
        guard context.targetVerified, context.focused, !context.systemShortcutActive,
              state == .active || state == .draining else { return .init(disposition: .pass, reason: nil) }
        let busy = !dispatcher.isQuiescent || !contacts.isEmpty || !captured.isEmpty
        if busy, let source { captured.insert(source) }
        stop()
        return .init(disposition: busy && context.targetVerified && context.focused ? .consume : .pass,
                     reason: .stopped)
    }

    @discardableResult
    public mutating func handle(_ event: InputEnvelope, context: InputContext) -> RoutingDecision {
        guard event.sequence > lastSequence, event.milliseconds >= lastEventMS else {
            stop(fault: .invalidOrder)
            return .init(disposition: source(event.action).map { captured.contains($0) } == true ? .consume : .pass,
                         reason: .fault)
        }
        lastSequence = event.sequence; lastEventMS = event.milliseconds
        refresh(context)
        checkHold(at: event.milliseconds)
        settle(context)
        updatePhysical(event.action)
        var decision = RoutingDecision(disposition: .pass, reason: nil)
        switch event.action {
        case .enable(let snapshot):
            if state == .disabled || state == .ready {
                physicalDown = Set(snapshot.keys.filter { isMappedKey($0) }.map(InputSource.key))
                if snapshot.left { physicalDown.insert(.left) }
                if snapshot.right { physicalDown.insert(.right) }
                wantsEnabled = true; state = .ready
            } else { decision = .init(disposition: .pass, reason: .notReady) }
        case .disable, .cancel: stop()
        case .tapStopped: stop(fault: .tapStopped)
        case .permissionLost: stop(fault: .permissionLost)
        case .systemShortcut: stop()
        case .tick: break
        case .keyDown(let code, let autorepeat):
            let key = InputSource.key(code)
            if captured.contains(key) { decision = .init(disposition: .consume, reason: nil) }
            else if state == .active, !autorepeat, profile.joystick?.keys.contains(code) == true {
                captured.insert(key); decision = updateJoystick(at: event.milliseconds)
            }
            else if state == .active, !autorepeat, let binding = profile.bindings.first(where: { $0.keyCode == code }) {
                if let pixel = try? calibration.pixels(binding.point) {
                    decision = press(key, point: pixel, at: event.milliseconds)
                } else { stop(fault: .invalidRequest); decision = .init(disposition: .consume, reason: .invalidGeometry) }
            } else if state == .draining, context.targetVerified, context.focused, !context.systemShortcutActive,
                      isMappedKey(code) {
                captured.insert(key); decision = .init(disposition: .consume, reason: .stopped)
            }
        case .keyUp(let code):
            if profile.joystick?.keys.contains(code) == true {
                guard captured.remove(.key(code)) != nil else { break }
                decision = state == .active ? updateJoystick(at: event.milliseconds) : .init(disposition: .consume, reason: nil)
            } else { decision = release(.key(code)) }
        case .leftDown(let point):
            if captured.contains(.left) { decision = .init(disposition: .consume, reason: nil) }
            else if state == .active, !point.finite, eligible(context) {
                captured.insert(.left); stop(fault: .invalidRequest)
                decision = .init(disposition: .consume, reason: .invalidGeometry)
            } else if (state == .active || state == .draining), context.targetVerified, context.focused,
                    !context.systemShortcutActive,
                    calibration.interactionRect.contains(point) {
                if state == .active, let pixel = try? calibration.pixels(point, clamp: false) {
                    decision = press(.left, point: pixel, at: event.milliseconds)
                } else {
                    captured.insert(.left); decision = .init(disposition: .consume, reason: .stopped)
                }
            } else if (state == .active || state == .draining), context.targetVerified, context.focused,
                      !context.systemShortcutActive, calibration.displayRect.contains(point) {
                // An excluded Guest area (e.g. navigation bars) can still
                // create official touches. Do not mix that stream with ours.
                decision = unsupported(context, source: .left)
            }
        case .leftMove(let point):
            if captured.contains(.left) {
                decision = .init(disposition: .consume, reason: nil)
                if state == .active, var contact = contacts[.left] {
                    if let pixel = try? calibration.pixels(point, clamp: true) {
                        if pixel != contact.point {
                            contact.point = pixel; contacts[.left] = contact
                            if !dispatcher.enqueue(.init(id: contact.id, point: pixel, phase: .move)) { stop() }
                        }
                    } else { stop(fault: .invalidRequest) }
                }
            }
        case .leftUp(let point):
            decision = release(.left, point: try? calibration.pixels(point, clamp: true))
        case .rightDown: decision = unsupported(context, source: .right)
        case .rightUp: decision = release(.right)
        case .scroll: decision = unsupported(context)
        }
        settle(context)
        return decision
    }

    /// The sole owner polls this outbox; do not copy a reducer into parallel
    /// senders. The future transport reports only its own request completion.
    public mutating func nextRequest(at milliseconds: Int64, context: InputContext) -> ContactRequest? {
        guard milliseconds >= lastEventMS else { stop(fault: .invalidOrder); return nil }
        refresh(context)
        checkHold(at: milliseconds)
        let request = dispatcher.next(at: milliseconds)
        settle(context)
        return request
    }

    @discardableResult
    public mutating func complete(sequence: UInt64, outcome: DispatchOutcome, context: InputContext) -> Bool {
        refresh(context)
        let completed = dispatcher.complete(sequence: sequence, outcome: outcome)
        settle(context)
        return completed
    }
}
