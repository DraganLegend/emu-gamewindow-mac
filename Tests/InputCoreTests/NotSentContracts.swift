import Testing
@testable import InputCore

private let firstPoint = PixelPoint(x: 10, y: 20)
private let nextPoint = PixelPoint(x: 30, y: 40)
private func requireMutation<T>(_ value: T?) throws -> T { try #require(value) }
private func expectMutation(_ value: Bool) { #expect(value) }

@Suite("NotSentContracts: prepared ticket is not an RPC attempt")
struct NotSentContracts {
    @Test(arguments: [false, true])
    func rejectedDownHasNoPhantomRelease(_ invalidated: Bool) throws {
        var out = try ContactDispatcher(sessionGeneration: 1)
        expectMutation(out.enqueue(.init(id: 10001, point: firstPoint, phase: .down)))
        let down = try requireMutation(out.next(at: 0))
        if invalidated { out.invalidateSession() }
        expectMutation(out.complete(sequence: down.sequence, outcome: .notSent))
        #expect(out.possibleContacts.isEmpty && out.uncertainIDs.isEmpty)
        let next = out.next(at: 1)
        #expect(next == nil)
    }

    @Test func rejectedMoveRestoresPreviousPointForOwnCleanup() throws {
        var out = try ContactDispatcher(sessionGeneration: 1)
        expectMutation(out.enqueue(.init(id: 10001, point: firstPoint, phase: .down)))
        let down = try requireMutation(out.next(at: 0))
        expectMutation(out.complete(sequence: down.sequence, outcome: .acknowledged))
        expectMutation(out.enqueue(.init(id: 10001, point: nextPoint, phase: .move)))
        let move = try requireMutation(out.next(at: 17))
        expectMutation(out.complete(sequence: move.sequence, outcome: .notSent))
        let up = try requireMutation(out.next(at: 18))
        #expect(up.cleanup && up.change.phase == .up && up.change.point == firstPoint)
    }

    @Test func rejectedNormalUpAllowsOneActualCleanupButRejectedCleanupNeverLoops() throws {
        var out = try ContactDispatcher(sessionGeneration: 1)
        expectMutation(out.enqueue(.init(id: 10001, point: firstPoint, phase: .down)))
        let down = try requireMutation(out.next(at: 0))
        expectMutation(out.complete(sequence: down.sequence, outcome: .acknowledged))
        expectMutation(out.enqueue(.init(id: 10001, point: firstPoint, phase: .up)))
        let normalUp = try requireMutation(out.next(at: 1))
        expectMutation(out.complete(sequence: normalUp.sequence, outcome: .notSent))
        let cleanup = try requireMutation(out.next(at: 2))
        #expect(cleanup.cleanup && cleanup.change.phase == .up)
        expectMutation(out.complete(sequence: cleanup.sequence, outcome: .notSent))
        #expect(out.uncertainIDs == [10001])
        let next = out.next(at: 3)
        #expect(next == nil)
    }
}
