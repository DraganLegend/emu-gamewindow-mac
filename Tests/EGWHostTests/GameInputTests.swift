import GRPCCore
import InputCore
import Testing
@testable import EGWHost

private func makeModel() throws -> GameInputModel {
    let profile = try MappingProfile(bindings: [.init(keyCode: 6, label: "skill", point: .init(x: 0.5, y: 0.75))])
    var model = try GameInputModel(profile: profile, width: 720, height: 1280, viewWidth: 360, viewHeight: 640)
    model.setFocused(true, at: 1)
    model.tick(at: 2)
    return model
}

/// Acknowledges every request in order, like a healthy sender, and returns them.
private func flush(_ model: inout GameInputModel, from start: Int64) -> [ContactRequest] {
    var out: [ContactRequest] = []
    var now = start
    for _ in 0..<40 {
        now += 20
        if let request = model.nextRequest(at: now) {
            out.append(request)
            model.complete(sequence: request.sequence, outcome: .acknowledged)
        }
    }
    return out
}

private let center = HostPoint(x: 180, y: 320)

@Suite("Own game window input", .timeLimit(.minutes(1)))
struct GameInputTests {
    @Test func focusedWindowArmsMapping() throws {
        var model = try makeModel()
        #expect(model.state == .active)
        model.setFocused(false, at: 10)
        _ = flush(&model, from: 10)
        model.tick(at: 1000)
        #expect(model.state == .disabled)
        model.setFocused(true, at: 1010)
        model.tick(at: 1020)
        #expect(model.state == .active)
    }

    @Test func mouseTapMapsViewPointToGuestPixel() throws {
        var model = try makeModel()
        let d1 = model.send(.leftDown(center), at: 10)
        #expect(d1 == .consume)
        let d2 = model.send(.leftUp(center), at: 50)
        #expect(d2 == .consume)
        let requests = flush(&model, from: 50)
        #expect(requests.map(\.change.phase) == [.down, .up])
        #expect(requests.allSatisfy { $0.change.id == 10001 && !$0.cleanup })
        #expect(requests.allSatisfy { $0.change.point == PixelPoint(x: 359, y: 639) })
        #expect(model.quiescent && model.heldContacts == 0)
    }

    @Test func skillKeyHoldsUntilReleaseAndIgnoresAutorepeat() throws {
        var model = try makeModel()
        let d3 = model.send(.keyDown(6, autorepeat: false), at: 10)
        #expect(d3 == .consume)
        let d4 = model.send(.keyDown(6, autorepeat: true), at: 200)
        #expect(d4 == .consume)
        let d5 = model.send(.keyUp(6), at: 600)
        #expect(d5 == .consume)
        let requests = flush(&model, from: 600)
        #expect(requests.map(\.change.phase) == [.down, .up])
        #expect(requests.allSatisfy { $0.change.point == PixelPoint(x: 359, y: 959) })
        #expect(model.quiescent)
    }

    @Test func keyAndMouseUseSeparateContactsReleasedIndependently() throws {
        var model = try makeModel()
        model.send(.keyDown(6, autorepeat: false), at: 10)
        model.send(.leftDown(center), at: 20)
        model.send(.keyUp(6), at: 100)
        model.send(.leftMove(HostPoint(x: 200, y: 340)), at: 110)
        model.send(.leftUp(HostPoint(x: 200, y: 340)), at: 200)
        let requests = flush(&model, from: 200)
        let downs = requests.filter { $0.change.phase == .down }
        #expect(downs.count == 2 && Set(downs.map(\.change.id)).count == 2)
        let ups = requests.filter { $0.change.phase == .up }
        #expect(ups.count == 2 && ups[0].change.id == downs[0].change.id && ups[1].change.id == downs[1].change.id)
        #expect(model.quiescent && model.heldContacts == 0)
    }

    @Test func unmappedKeyAndOutsidePointAreNotCaptured() throws {
        var model = try makeModel()
        let d6 = model.send(.keyDown(7, autorepeat: false), at: 10)
        #expect(d6 == .pass)
        let d7 = model.send(.leftDown(HostPoint(x: 400, y: 100)), at: 20)
        #expect(d7 == .pass)
        #expect(flush(&model, from: 20).isEmpty)
    }

    @Test func losingKeyStatusReleasesHeldContact() throws {
        var model = try makeModel()
        model.send(.keyDown(6, autorepeat: false), at: 10)
        var requests = flush(&model, from: 10)
        #expect(requests.map(\.change.phase) == [.down])
        model.setFocused(false, at: 300)
        requests = flush(&model, from: 300)
        #expect(requests.count == 1 && requests[0].change.phase == .up && requests[0].cleanup)
        #expect(model.quiescent)
    }

    @Test func failedSendFaultsWithoutRetry() throws {
        var model = try makeModel()
        model.send(.keyDown(6, autorepeat: false), at: 10)
        let first = model.nextRequest(at: 30)
        let request = try #require(first)
        model.complete(sequence: request.sequence, outcome: .failed)
        #expect(model.faulted)
        // The possibly-delivered down gets exactly one cleanup release, never a resend.
        let cleanup = model.nextRequest(at: 100)
        #expect(cleanup?.change.phase == .up && cleanup?.cleanup == true && cleanup?.change.id == request.change.id)
        if let cleanup { model.complete(sequence: cleanup.sequence, outcome: .acknowledged) }
        let later = model.nextRequest(at: 200)
        #expect(later == nil && model.faulted)
    }

    @Test func parsesOptionsWithoutInlineBindings() throws {
        let ok = try GameViewOptions.parse(["game-view", "--session", "/s.json", "--seconds", "60", "--flip-frames"])
        #expect(ok.flipFrames && !ok.gameInUse && ok.seconds == 60)
        let bad: [[String]] = [
            ["game-view", "--seconds", "60"],
            ["game-view", "--session", "/s.json", "--seconds", "29"],
            ["game-view", "--session", "/s.json", "--seconds", "60", "--skill", "6,0.5,0.5"],
            ["game-view", "--session", "/s.json", "--seconds", "60", "--token", "x"],
        ]
        for args in bad { #expect(throws: ProbeFailure.self) { _ = try GameViewOptions.parse(args) } }
    }

    @Test func profileAllowsEmptyAndEightButNotNineBindings() throws {
        #expect(try MappingProfile(bindings: []).bindings.isEmpty)
        func keys(_ count: Int) -> [SkillBinding] {
            (0..<count).map { .init(keyCode: UInt16($0), label: "k\($0)", point: .init(x: 0.5, y: 0.5)) }
        }
        #expect(try MappingProfile(bindings: keys(8)).bindings.count == 8)
        #expect(throws: InputCoreError.self) { _ = try MappingProfile(bindings: keys(9)) }
    }

    @Test func emptyKeymapStillPassesMouse() throws {
        var model = try GameInputModel(profile: MappingProfile(bindings: []), width: 720, height: 1280,
                                       viewWidth: 360, viewHeight: 640)
        model.setFocused(true, at: 1); model.tick(at: 2)
        let down = model.send(.leftDown(center), at: 10)
        let key = model.send(.keyDown(6, autorepeat: false), at: 20)
        #expect(down == .consume && key == .pass)
    }

    @Test func keymapStoreRoundTripIsPrivateAndAtomic() {
        #expect(keymapStoreChecks())
    }

    @Test func frameRendererValidatesLayout() {
        #expect(frameRendererChecks())
    }
}
