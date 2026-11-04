import Testing
@testable import InputCore

private let inside = HostPoint(x: 200, y: 300)
private let moved = HostPoint(x: 260, y: 350)
private let outside = HostPoint(x: -100, y: 1000)
private let skill = SkillBinding(keyCode: 0, label: "Synthetic skill", point: .init(x: 0.25, y: 0.5))

// Evaluate mutating expressions before Testing's function-call capture macro;
// otherwise its diagnostic closure captures a value-type receiver immutably.
private func verifyMutation(_ result: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result, sourceLocation: sourceLocation)
}
private func required<Value>(_ result: Value?, sourceLocation: SourceLocation = #_sourceLocation) throws -> Value {
    try #require(result, sourceLocation: sourceLocation)
}

/// No networking: completion stays under each test's control, including delays
/// and timeouts. A second start without completion is an explicit violation.
private struct FakeSink {
    var requests: [ContactRequest] = []
    var active: UInt64?
    var maxInFlight = 0
    mutating func start(_ request: ContactRequest) {
        #expect(active == nil)
        active = request.sequence; maxInFlight = max(maxInFlight, active == nil ? 0 : 1)
        requests.append(request)
    }
    mutating func finish(_ request: ContactRequest) {
        #expect(active == request.sequence); active = nil
    }
}

private struct Rig {
    var core: InputReducer
    var context = InputContext(targetVerified: true, focused: true,
                               calibrationGeneration: 1, sessionGeneration: 1, permissionAvailable: true)
    var sink = FakeSink()
    var time: Int64 = 0
    var sequence: UInt64 = 0
    init(twoBindings: Bool = false, capacity: Int = 32) throws {
        let profile = try MappingProfile(bindings: twoBindings
            ? [skill, .init(keyCode: 1, label: "Second", point: .init(x: 0.75, y: 0.5))] : [skill])
        let calibration = try InputCalibration(generation: 1, width: 720, height: 1280, rotation: 0,
            displayRect: .init(x: 0, y: 0, width: 360, height: 640),
            interactionRect: .init(x: 20, y: 100, width: 320, height: 500))
        core = try .init(profile: profile, calibration: calibration, sessionGeneration: 1, queueEdgeCapacity: capacity)
    }
    @discardableResult mutating func send(_ action: InputAction, at: Int64? = nil) -> RoutingDecision {
        sequence += 1; time = at ?? time + 1
        return core.handle(.init(sequence: sequence, milliseconds: time, action: action), context: context)
    }
    mutating func enable(_ physical: PhysicalSnapshot = .init()) {
        send(.enable(physical))
    }
    mutating func issue() -> ContactRequest? {
        let request = core.nextRequest(at: time, context: context)
        if let request { sink.start(request) }
        return request
    }
    mutating func finish(_ request: ContactRequest, _ outcome: DispatchOutcome = .acknowledged) {
        sink.finish(request)
        verifyMutation(core.complete(sequence: request.sequence, outcome: outcome, context: context))
    }
    mutating func drain() {
        for _ in 0..<64 {
            time += 17
            guard let request = issue() else { return }
            finish(request)
        }
        Issue.record("Outbox did not settle within its finite test budget")
    }
}

@Suite("InputCore C01-C20 offline contracts")
struct InputCoreContracts {
    @Test func C01_disabledPassesWithoutTouch() throws {
        var r = try Rig()
        #expect(r.send(.keyDown(0, autorepeat: false)).disposition == .pass)
        #expect(r.send(.leftDown(inside)).disposition == .pass)
        r.drain()
        #expect(r.sink.requests.isEmpty && r.core.contacts.isEmpty)
    }

    @Test(arguments: ["other-app", "wrong-window", "unbound"])
    func C02_onlyTargetAndConfiguredKeys(_ kind: String) throws {
        var r = try Rig(); r.enable()
        if kind == "other-app" { r.context.focused = false }
        if kind == "wrong-window" { r.context.targetVerified = false }
        #expect(r.send(.keyDown(kind == "unbound" ? 8 : 0, autorepeat: false)).disposition == .pass)
        r.drain()
        #expect(r.sink.requests.isEmpty)
        #expect(!r.core.physicalDown.contains(.key(8)))
    }

    @Test func C03_autorepeatDoesNotDuplicateContact() throws {
        var r = try Rig(); r.enable()
        #expect(r.send(.keyDown(0, autorepeat: false)).disposition == .consume)
        for _ in 0..<5 { #expect(r.send(.keyDown(0, autorepeat: true)).disposition == .consume) }
        #expect(r.send(.keyUp(0)).disposition == .consume)
        r.drain()
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
        #expect(Set(r.sink.requests.map(\.change.id)).count == 1)
        #expect(r.core.dispatcher.isQuiescent && r.core.captured.isEmpty)
    }

    @Test func C04_mouseAndSkillHaveIndependentIDsAndPositions() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false)); r.drain()
        let a = try #require(r.core.contacts[.key(0)])
        r.send(.leftDown(inside)); r.drain()
        let b = try #require(r.core.contacts[.left])
        #expect(a.id != b.id)
        r.send(.leftMove(moved)); r.drain()
        #expect(r.core.contacts[.key(0)] == a)
        #expect(r.sink.requests.last?.change.id == b.id)
        #expect(r.sink.requests.last?.change.point == PixelPoint(x: 519, y: 699))
    }

    @Test(arguments: [false, true])
    func C05_C06_bothIndependentReleaseOrders(_ mouseFirst: Bool) throws {
        var r = try Rig(); r.enable()
        var counts: [Int] = []
        r.send(.keyDown(0, autorepeat: false)); r.drain(); counts.append(r.core.contacts.count)
        r.send(.leftDown(inside)); r.drain(); counts.append(r.core.contacts.count)
        r.send(.leftMove(moved)); r.drain(); counts.append(r.core.contacts.count)
        let a = try #require(r.core.contacts[.key(0)]), b = try #require(r.core.contacts[.left])
        if mouseFirst { r.send(.leftUp(moved)) } else { r.send(.keyUp(0)) }
        r.drain(); counts.append(r.core.contacts.count)
        if !mouseFirst { r.send(.leftMove(inside)); r.drain(); counts.append(r.core.contacts.count) }
        if mouseFirst { r.send(.keyUp(0)) } else { r.send(.leftUp(inside)) }
        r.drain(); counts.append(r.core.contacts.count)
        #expect(counts == (mouseFirst ? [1, 2, 2, 1, 0] : [1, 2, 2, 1, 1, 0]))
        let releases = r.sink.requests.filter { $0.change.phase == .up }.map(\.change.id)
        #expect(releases == (mouseFirst ? [b.id, a.id] : [a.id, b.id]))
        #expect(r.core.dispatcher.isQuiescent && r.core.captured.isEmpty)
    }

    @Test func C07_mouseOwnershipFollowsTheOriginalDown() throws {
        var r = try Rig(); r.enable()
        #expect(r.send(.leftDown(outside)).disposition == .pass)
        #expect(r.send(.leftMove(inside)).disposition == .pass)
        #expect(r.send(.leftUp(inside)).disposition == .pass)
        #expect(r.sink.requests.isEmpty && r.core.contacts.isEmpty)
        #expect(r.send(.leftDown(inside)).disposition == .consume); r.drain()
        #expect(r.send(.leftMove(outside)).disposition == .consume); r.drain()
        #expect(r.send(.leftUp(outside)).disposition == .consume); r.drain()
        #expect(r.sink.requests.last?.change.point == PixelPoint(x: 0, y: 1279))
        #expect(r.core.dispatcher.isQuiescent)
    }

    @Test(arguments: ["disable", "cancel", "blur"])
    func C08_stopDrainsOwnedContactsAndKeepsPhysicalPairs(_ kind: String) throws {
        var r = try Rig(); r.enable()
        r.send(.keyDown(0, autorepeat: false)); r.send(.leftDown(inside)); r.drain()
        if kind == "blur" { r.context.focused = false; r.send(.tick) }
        else { r.send(kind == "disable" ? .disable : .cancel) }
        #expect(r.core.state == .draining && r.core.contacts.isEmpty)
        r.drain()
        #expect(r.core.state == .draining)
        #expect(r.sink.requests.filter(\.cleanup).map(\.change.phase) == [.up, .up])
        #expect(r.send(.keyDown(0, autorepeat: true)).disposition == .consume)
        #expect(r.send(.keyUp(0)).disposition == .consume)
        #expect(r.send(.leftUp(outside)).disposition == .consume)
        #expect(r.core.state == .disabled)
        r.context.focused = true
        #expect(r.send(.keyDown(0, autorepeat: false)).disposition == .pass)
    }

    @Test func C09_noSyntheticDownWhenArmingHeldPhysicalInputs() throws {
        var r = try Rig(); r.enable(.init(keys: [0], left: true))
        #expect(r.core.state == .ready)
        #expect(r.send(.keyDown(0, autorepeat: true)).disposition == .pass)
        #expect(r.send(.keyUp(0)).disposition == .pass)
        #expect(r.core.state == .ready)
        #expect(r.send(.leftUp(inside)).disposition == .pass)
        #expect(r.core.state == .active && r.core.contacts.isEmpty)
        r.drain(); #expect(r.sink.requests.isEmpty)
        #expect(r.send(.keyDown(0, autorepeat: false)).disposition == .consume)
    }

    @Test func C10_geometryInvalidationDropsUnsentDownWithoutPhantomUp() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false)); r.drain()
        let a = try #require(r.core.contacts[.key(0)])
        r.send(.leftDown(inside)) // Not dispatched.
        let oldGeneration = r.core.generation
        r.context.calibrationGeneration = 2; r.send(.tick); r.drain()
        #expect(r.core.generation > oldGeneration)
        #expect(r.sink.requests.map(\.change.id) == [a.id, a.id])
        #expect(r.sink.requests.last?.cleanup == true)
        #expect(r.send(.keyUp(0)).disposition == .consume)
        #expect(r.send(.leftUp(inside)).disposition == .consume)
        r.enable(); #expect(r.core.state == .ready)
    }

    @Test(arguments: [1.0, 2.0])
    func C11_coordinatesUseTheWholeDisplayAndRejectNonFiniteValues(_ scale: Double) throws {
        let rect = HostRect(x: -1400, y: -600, width: 720 / scale, height: 1280 / scale)
        let c = try InputCalibration(generation: 1, width: 720, height: 1280, rotation: 0,
                                     displayRect: rect, interactionRect: rect)
        #expect(try c.pixels(NormalizedPoint(x: 0, y: 0)) == PixelPoint(x: 0, y: 0))
        #expect(try c.pixels(NormalizedPoint(x: 1, y: 1)) == PixelPoint(x: 719, y: 1279))
        #expect(try c.pixels(HostPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), clamp: false)
                == PixelPoint(x: 359, y: 639))
        #expect(throws: InputCoreError.self) { try c.pixels(HostPoint(x: .nan, y: 0), clamp: true) }
        #expect(throws: InputCoreError.self) { try c.pixels(NormalizedPoint(x: .infinity, y: 0)) }
        for width in [0.0, -1, .infinity, .nan] {
            #expect(throws: InputCoreError.self) {
                try InputCalibration(generation: 1, width: 720, height: 1280, rotation: 0,
                    displayRect: .init(x: 0, y: 0, width: width, height: 100), interactionRect: rect)
            }
        }
    }

    @Test func C12_coalescingRespectsEdgesAndRateLimit() throws {
        var d = try ContactDispatcher(sessionGeneration: 1)
        func change(_ id: Int32, _ phase: ContactPhase, _ x: Int) -> ContactChange {
            .init(id: id, point: .init(x: x, y: 1), phase: phase)
        }
        verifyMutation(d.enqueue(change(10001, .down, 0)))
        let down = try required(d.next(at: 0)); d.complete(sequence: down.sequence, outcome: .acknowledged)
        verifyMutation(d.enqueue(change(10001, .move, 10)))
        verifyMutation(d.enqueue(change(10002, .down, 0)))
        verifyMutation(d.enqueue(change(10001, .move, 20)))
        verifyMutation(d.enqueue(change(10001, .move, 30)))
        verifyMutation(d.enqueue(change(10001, .up, 40)))
        var emitted: [ContactChange] = []
        for t: Int64 in [1, 2, 18, 19] {
            let q = try required(d.next(at: t)); emitted.append(q.change)
            d.complete(sequence: q.sequence, outcome: .acknowledged)
        }
        #expect(emitted.map(\.phase) == [.move, .down, .move, .up])
        #expect(emitted.map(\.point.x) == [10, 0, 30, 40])
        var times: [Int64] = []
        for t: Int64 in 20..<1020 {
            verifyMutation(d.enqueue(change(10002, .move, Int(t))))
            if let q = d.next(at: t) { times.append(t); d.complete(sequence: q.sequence, outcome: .acknowledged) }
        }
        #expect(times.count <= 60)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 17 })
    }

    @Test func C13_delayedSinkCannotReceiveASecondRequestBeforeCompletion() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false))
        let first = try required(r.issue())
        r.send(.leftDown(inside))
        for _ in 0..<10 { r.time += 1; #expect(r.core.nextRequest(at: r.time, context: r.context) == nil) }
        #expect(r.sink.requests.count == 1)
        verifyMutation(!r.core.complete(sequence: first.sequence + 99, outcome: .acknowledged, context: r.context))
        r.finish(first); r.drain()
        #expect(r.sink.requests.count == 2 && r.sink.maxInFlight == 1)
        #expect(r.sink.requests.map(\.sessionGeneration) == [1, 1])
    }

    @Test(arguments: ["down-failed", "down-timeout", "move-failed", "move-timeout"])
    func C14_failedOrTimedOutDownMoveGetsAtMostOneOwnRelease(_ kind: String) throws {
        var r = try Rig(); r.enable()
        r.send(.leftDown(inside))
        if kind.hasPrefix("move") { r.drain(); r.send(.leftMove(moved)) }
        let failed = try required(r.issue())
        r.finish(failed, kind.hasSuffix("timeout") ? .timedOut : .failed)
        #expect(r.core.state == .faulted)
        r.drain()
        #expect(r.sink.requests.filter(\.cleanup).map(\.change.phase) == [.up])
        #expect(r.sink.requests.last?.change.id == failed.change.id)
        #expect(r.core.dispatcher.uncertainIDs.isEmpty && r.core.dispatcher.isQuiescent)
        r.send(.leftUp(inside)); r.enable()
        #expect(r.core.state == .faulted) // A clean ACK is not automatic re-arming.
    }

    @Test func C15_failedUpIsNeverRetriedOrReportedSafe() throws {
        var r = try Rig(); r.enable(); r.send(.leftDown(inside)); r.drain(); r.send(.leftUp(inside))
        let up = try required(r.issue()); r.finish(up, .failed); r.drain()
        #expect(r.core.dispatcher.uncertainIDs == [up.change.id])
        #expect(!r.core.dispatcher.isQuiescent)
        #expect(r.sink.requests.filter { $0.change.phase == .up }.count == 1)
        r.enable(); #expect(r.core.state == .faulted)
    }

    @Test(arguments: [false, true])
    func C16_cancelInFlightNeverSendsQueuedDownToANewSession(_ changeSession: Bool) throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false))
        let first = try required(r.issue()); r.send(.leftDown(inside))
        if changeSession { r.context.sessionGeneration = 2 }
        r.send(.cancel)
        #expect(r.core.nextRequest(at: r.time, context: r.context) == nil)
        r.finish(first); r.drain()
        #expect(r.sink.requests.filter { $0.change.phase == .down }.count == 1)
        if changeSession {
            #expect(r.sink.requests.count == 1)
            #expect(r.core.dispatcher.uncertainIDs == [first.change.id])
        } else {
            #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
            #expect(r.sink.requests.last?.cleanup == true)
        }
    }

    @Test func C17_overflowReservesCancelAndReleasesOnlyActuallySentContact() throws {
        var r = try Rig(capacity: 1); r.enable(); r.send(.keyDown(0, autorepeat: false))
        let first = try required(r.issue()); r.send(.leftDown(inside)); r.send(.keyUp(0))
        #expect(r.core.state == .faulted && r.core.dispatcher.fault == .overflow)
        r.send(.cancel); r.finish(first); r.drain()
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
        #expect(r.sink.requests.last?.change.id == first.change.id)
        #expect(r.send(.leftUp(inside)).disposition == .consume)
    }

    @Test(arguments: [InputAction.tapStopped, .permissionLost])
    func C17_tapAndPermissionFaultsDoNotAutoResume(_ action: InputAction) throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false)); r.drain()
        r.send(action); r.drain(); r.send(.keyUp(0)); r.enable()
        #expect(r.core.state == .faulted)
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
    }

    @Test func C18_profileValidationAndCapacityRejectionAreExplicit() throws {
        #expect(throws: InputCoreError.self) { try MappingProfile(schema: 2, bindings: [skill]) }
        #expect(throws: InputCoreError.self) { try MappingProfile(bindings: [skill, skill]) }
        #expect(throws: InputCoreError.self) {
            try MappingProfile(bindings: [.init(keyCode: 55, label: "Command", point: .init(x: 0.5, y: 0.5))])
        }
        for x in [-1.0, 1.1, .nan, .infinity] {
            #expect(throws: InputCoreError.self) {
                try MappingProfile(bindings: [.init(keyCode: 0, label: "Bad", point: .init(x: x, y: 0.5))])
            }
        }
        #expect(throws: InputCoreError.self) { try decodeInvalidProfileFixture() }
        #expect(try profileRoundTripFixture(MappingProfile(bindings: [skill])))
        var r = try Rig(twoBindings: true); r.enable()
        r.send(.keyDown(0, autorepeat: false)); r.send(.keyDown(1, autorepeat: false)); r.drain()
        #expect(r.send(.leftDown(inside)).reason == .contactLimit)
        #expect(r.core.contacts.count == 2)
        #expect(r.send(.leftUp(inside)).disposition == .consume)
        r.send(.keyUp(0)); r.send(.keyUp(1)); r.drain()
        #expect(r.sink.requests.map(\.change.phase) == [.down, .down, .up, .up])
    }

    @Test func C19_holdLimitStopsOnceWithoutRepeating() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false)); r.drain()
        r.send(.tick, at: 10_100); r.drain()
        #expect(r.core.state == .draining)
        #expect(r.send(.keyDown(0, autorepeat: true)).disposition == .consume)
        r.send(.keyUp(0)); r.drain()
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
        #expect(r.core.state == .disabled)
    }

    @Test(arguments: ["right", "scroll", "shortcut", "other-app-right"])
    func C20_unsupportedInputsHaveExplicitHandoff(_ kind: String) throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false)); r.drain()
        if kind == "other-app-right" { r.context.focused = false }
        let action: InputAction = kind == "scroll" ? .scroll : kind == "shortcut" ? .systemShortcut : .rightDown
        let result = r.send(action)
        #expect(result.disposition == (kind == "shortcut" || kind == "other-app-right" ? .pass : .consume))
        r.drain()
        if kind == "right" { #expect(r.send(.rightUp).disposition == .consume) }
        if kind == "other-app-right" {
            #expect(!r.core.captured.contains(.right))
            #expect(r.send(.rightUp).disposition == .pass)
        }
        #expect(r.send(.keyUp(0)).disposition == .consume)
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
        #expect(r.core.state == .disabled)
    }

    @Test func C20_idleUnsupportedMouseOperationReturnsToOfficialRoute() throws {
        var r = try Rig(); r.enable()
        #expect(r.send(.rightDown).disposition == .pass)
        #expect(r.send(.rightUp).disposition == .pass)
        #expect(r.core.state == .disabled && r.core.dispatcher.isQuiescent)
    }

    @Test(arguments: [false, true])
    func C20_excludedGuestAreaCannotCreateASecondTouchStream(_ busy: Bool) throws {
        var r = try Rig(); r.enable()
        if busy { r.send(.keyDown(0, autorepeat: false)); r.drain() }
        // Inside the whole Guest display but outside the game interaction ROI.
        let excluded = HostPoint(x: 10, y: 50)
        #expect(r.send(.leftDown(excluded)).disposition == (busy ? .consume : .pass))
        #expect(r.core.state == .draining)
        if !busy { #expect(r.send(.keyDown(0, autorepeat: false)).disposition == .consume) }
        #expect(r.send(.leftUp(excluded)).disposition == (busy ? .consume : .pass))
        #expect(r.send(.keyUp(0)).disposition == .consume)
        r.drain()
        #expect(r.core.state == .disabled)
        #expect(r.sink.requests.map(\.change.phase) == (busy ? [.down, .up] : []))
    }

    @Test func contextDefaultsCannotArmAndPermissionRevocationFaults() throws {
        var r = try Rig()
        r.context = .init(calibrationGeneration: 1, sessionGeneration: 1)
        r.enable(); #expect(r.core.state == .ready)
        r.send(.keyDown(0, autorepeat: false)); r.drain()
        #expect(r.sink.requests.isEmpty)
        var live = try Rig(); live.enable(); live.send(.keyDown(0, autorepeat: false)); live.drain()
        live.context.permissionAvailable = false; live.send(.tick); live.drain()
        #expect(live.core.state == .faulted && live.core.dispatcher.fault == .permissionLost)
    }

    @Test func systemShortcutDoesNotCaptureANewMappedKey() throws {
        var r = try Rig(twoBindings: true); r.enable()
        r.send(.keyDown(0, autorepeat: false)); r.drain()
        r.context.systemShortcutActive = true
        #expect(r.send(.keyDown(1, autorepeat: false)).disposition == .pass)
        #expect(!r.core.captured.contains(.key(1)))
        #expect(r.send(.keyUp(1)).disposition == .pass)
        r.drain(); #expect(r.send(.keyUp(0)).disposition == .consume)
        #expect(r.sink.requests.map(\.change.phase) == [.down, .up])
    }

    @Test func acknowledgmentAfterBlurCannotKeepMappingActive() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false))
        let first = try required(r.issue())
        r.context.focused = false; r.finish(first)
        #expect(r.core.state == .draining)
        r.drain(); #expect(r.sink.requests.last?.cleanup == true)
    }

    @Test func nonFiniteMouseDownFailsWithoutTouchAndStillPairsItsUp() throws {
        var r = try Rig(); r.enable()
        #expect(r.send(.leftDown(.init(x: .nan, y: 0))).reason == .invalidGeometry)
        #expect(r.send(.leftUp(inside)).disposition == .consume)
        r.drain(); #expect(r.sink.requests.isEmpty && r.core.state == .faulted)
    }

    @Test func staleEventOrPollFaultsRatherThanReorderingInput() throws {
        var r = try Rig(); r.enable(); r.send(.keyDown(0, autorepeat: false))
        #expect(r.core.nextRequest(at: 0, context: r.context) == nil)
        #expect(r.core.state == .faulted)
        r.drain(); #expect(r.sink.requests.isEmpty)
        var other = try Rig(); other.enable(); other.send(.keyDown(0, autorepeat: false)); other.drain()
        let result = other.core.handle(.init(sequence: other.sequence, milliseconds: other.time, action: .keyUp(0)), context: other.context)
        #expect(result.disposition == .consume && other.core.state == .faulted)
        other.drain(); #expect(other.sink.requests.map(\.change.phase) == [.down, .up])
    }
}
