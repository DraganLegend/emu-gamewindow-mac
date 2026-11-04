import Testing
@testable import InputCore

// Game-window limits: more contacts, per-contact hold release,
// and a four-key virtual stick. The legacy defaults are covered by C01-C20.

private let stick = JoystickBinding(center: .init(x: 0.25, y: 0.75), radius: 0.1, up: 13, down: 1, left: 0, right: 2)
private let skills: [SkillBinding] = [
    .init(keyCode: 14, label: "E", point: .init(x: 0.7, y: 0.7)),
    .init(keyCode: 15, label: "R", point: .init(x: 0.8, y: 0.6)),
    .init(keyCode: 17, label: "T", point: .init(x: 0.9, y: 0.5)),
]
// Unit display rect, as GameInputModel uses it; 720x1280 Guest pixels.
private let unit = HostRect(x: 0, y: 0, width: 1, height: 1)

private struct GameRig {
    var core: InputReducer
    let context = InputContext(targetVerified: true, focused: true,
                               calibrationGeneration: 1, sessionGeneration: 1, permissionAvailable: true)
    var sent: [ContactRequest] = []
    var time: Int64 = 0
    var sequence: UInt64 = 0

    init(limits: ContactLimits = .game, joystick: JoystickBinding? = stick) throws {
        let profile = try MappingProfile(bindings: skills, joystick: joystick)
        let calibration = try InputCalibration(generation: 1, width: 720, height: 1280, rotation: 0,
                                               displayRect: unit, interactionRect: unit)
        core = try .init(profile: profile, calibration: calibration, sessionGeneration: 1, limits: limits)
        send(.enable(.init()))
    }
    @discardableResult mutating func send(_ action: InputAction, at: Int64? = nil) -> RoutingDecision {
        sequence += 1; time = at ?? time + 1
        return core.handle(.init(sequence: sequence, milliseconds: time, action: action), context: context)
    }
    mutating func drain() {
        for _ in 0..<64 {
            time += 17
            guard let request = core.nextRequest(at: time, context: context) else { return }
            sent.append(request)
            _ = core.complete(sequence: request.sequence, outcome: .acknowledged, context: context)
        }
        Issue.record("Outbox did not settle")
    }
    var phases: [ContactPhase] { sent.map(\.change.phase) }
}

@Suite("Game window limits and joystick")
struct GameLimitContracts {
    @Test func profileSchemaFollowsJoystick() throws {
        #expect(try MappingProfile(bindings: skills).schema == 1)
        #expect(try MappingProfile(bindings: skills, joystick: stick).schema == 2)
        #expect(throws: InputCoreError.self) { try MappingProfile(schema: 1, bindings: [], joystick: stick) }
        #expect(throws: InputCoreError.self) { try MappingProfile(schema: 2, bindings: []) }
        // A stick key may not double as a skill key, and radius stays bounded.
        #expect(throws: InputCoreError.self) {
            try MappingProfile(bindings: [.init(keyCode: 13, label: "W", point: .init(x: 0.5, y: 0.5))], joystick: stick)
        }
        #expect(throws: InputCoreError.self) {
            try MappingProfile(bindings: [], joystick: .init(center: .init(x: 0.5, y: 0.5), radius: 0.9,
                                                             up: 13, down: 1, left: 0, right: 2))
        }
        #expect(stick.withRadius(5).radius == JoystickBinding.radiusRange.upperBound)
    }

    @Test func limitsRejectBadConfigurations() {
        #expect(throws: InputCoreError.self) { try ContactLimits(contactIDs: [], hold: .stopAll(ms: 10_000)) }
        #expect(throws: InputCoreError.self) { try ContactLimits(contactIDs: [10001, 10001], hold: .stopAll(ms: 10_000)) }
        #expect(throws: InputCoreError.self) { try ContactLimits(contactIDs: [20000], hold: .stopAll(ms: 10_000)) }
        #expect(throws: InputCoreError.self) { try ContactLimits(contactIDs: [10001], hold: .releaseContact(ms: 10)) }
        #expect(ContactLimits.legacy.contactIDs == [10001, 10002])
    }

    @Test func fiveContactsAtOnceThenSixthIsRefused() throws {
        var r = try GameRig()
        r.send(.keyDown(13, autorepeat: false))     // stick
        r.send(.keyDown(14, autorepeat: false))     // E
        r.send(.keyDown(15, autorepeat: false))     // R
        r.send(.keyDown(17, autorepeat: false))     // T
        r.send(.leftDown(.init(x: 0.5, y: 0.5)))    // mouse
        r.drain()
        #expect(r.core.contacts.count == 5)
        #expect(Set(r.sent.filter { $0.change.phase == .down }.map(\.change.id)) == Set(ContactLimits.game.contactIDs))
        // Legacy limits keep the original two-slot refusal.
        var legacy = try GameRig(limits: .legacy)
        legacy.send(.keyDown(14, autorepeat: false)); legacy.send(.keyDown(15, autorepeat: false))
        #expect(legacy.send(.keyDown(17, autorepeat: false)).reason == .contactLimit)
        // Releasing everything leaves nothing held.
        for code: UInt16 in [13, 14, 15, 17] { r.send(.keyUp(code)) }
        r.send(.leftUp(.init(x: 0.5, y: 0.5))); r.drain()
        #expect(r.core.contacts.isEmpty && r.core.dispatcher.isQuiescent && r.core.state == .active)
    }

    @Test func longHoldLiftsOnlyThatContact() throws {
        var r = try GameRig()
        r.send(.keyDown(14, autorepeat: false), at: 10)
        r.send(.leftDown(.init(x: 0.5, y: 0.5)), at: 200_000); r.drain()
        r.send(.tick, at: 300_100); r.drain()
        // E is lifted, the mouse contact and the mapping stay.
        #expect(r.core.state == .active)
        #expect(r.core.contacts[.key(14)] == nil && r.core.contacts[.left] != nil)
        #expect(r.phases == [.down, .down, .up])
        // E's late physical up is consumed without a second up.
        #expect(r.send(.keyUp(14)).disposition == .consume)
        r.drain()
        #expect(r.phases == [.down, .down, .up])
        // A fresh press works again.
        r.send(.keyDown(14, autorepeat: false)); r.drain()
        #expect(r.core.contacts[.key(14)] != nil)
    }

    @Test func legacyHoldStillStopsEverything() throws {
        var r = try GameRig(limits: .legacy)
        r.send(.keyDown(14, autorepeat: false), at: 10); r.drain()
        r.send(.tick, at: 10_200); r.drain()
        #expect(r.core.state == .draining)
    }

    @Test func stickGoesDownAtCenterThenMovesAndLifts() throws {
        var r = try GameRig()
        let center = PixelPoint(x: Int(0.25 * 719), y: Int(0.75 * 1279))
        let reach = 0.1 * 720
        r.send(.keyDown(2, autorepeat: false)); r.drain()        // D = right
        #expect(r.phases == [.down, .move])
        #expect(r.sent[0].change.point == center)
        #expect(r.sent[1].change.point == .init(x: center.x + Int(reach.rounded()), y: center.y))
        #expect(r.send(.keyDown(2, autorepeat: true)).disposition == .consume)
        r.send(.keyDown(13, autorepeat: false)); r.drain()       // + W = up-right
        let diagonal = Int((reach / 2.0.squareRoot()).rounded())
        #expect(r.sent.last?.change.point == .init(x: center.x + diagonal, y: center.y - diagonal))
        #expect(Set(r.sent.map(\.change.id)).count == 1)
        r.send(.keyUp(2)); r.drain()                             // W only
        #expect(r.sent.last?.change.point == .init(x: center.x, y: center.y - Int(reach.rounded())))
        r.send(.keyUp(13)); r.drain()
        #expect(r.phases == [.down, .move, .move, .move, .up])
        #expect(r.core.contacts.isEmpty && r.core.captured.isEmpty)
    }

    @Test func oppositeKeysRestAtCenterWithoutLifting() throws {
        var r = try GameRig()
        r.send(.keyDown(0, autorepeat: false)); r.send(.keyDown(2, autorepeat: false)); r.drain()
        #expect(r.core.contacts[.joystick] != nil)
        #expect(r.sent.last?.change.point == PixelPoint(x: Int(0.25 * 719), y: Int(0.75 * 1279)))
        #expect(!r.phases.contains(.up))
    }

    @Test func stickReleasesOnCancelAndKeysAreConsumedUntilUp() throws {
        var r = try GameRig()
        r.send(.keyDown(1, autorepeat: false)); r.drain()
        r.send(.cancel); r.drain()
        #expect(r.phases.last == .up && r.core.contacts.isEmpty)
        #expect(r.send(.keyUp(1)).disposition == .consume)
        #expect(r.core.captured.isEmpty)
    }

    @Test func stickWithoutProfileKeysPassesThem() throws {
        var r = try GameRig(joystick: nil)
        #expect(r.send(.keyDown(13, autorepeat: false)).disposition == .pass)
    }
}
