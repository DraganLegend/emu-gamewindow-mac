import InputCore
import Testing
@testable import EGWHost

private func editor(_ bindings: [SkillBinding] = []) -> KeymapEditor {
    KeymapEditor(bindings: bindings, viewWidth: 360, viewHeight: 640)
}

private let z = SkillBinding(keyCode: 6, label: "Z", point: .init(x: 0.5, y: 0.5))

@Suite("Keymap editor", .timeLimit(.minutes(1)))
struct KeymapEditorTests {
    @Test func clickThenKeyBindsAtThePlaceChosen() {
        var e = editor()
        e.click(x: 90, y: 160)
        #expect(e.pending == NormalizedPoint(x: 0.25, y: 0.25))
        let outcome = e.key(6)
        #expect(outcome == .bound(0))
        #expect(e.pending == nil)
        #expect(e.bindings.map(\.keyCode) == [6] && e.bindings[0].label == "Z")
        #expect(e.bindings[0].point == NormalizedPoint(x: 0.25, y: 0.25))
    }

    @Test func keyWithoutAChosenPlaceDoesNothing() {
        var e = editor()
        let outcome = e.key(6)
        #expect(outcome == .none && e.bindings.isEmpty)
    }

    @Test func clickingAMarkerSelectsItAndANewKeyRebindsInPlace() {
        var e = editor([z])
        e.click(x: 180 + 5, y: 320 - 5)
        #expect(e.selected == 0 && e.pending == nil)
        let outcome = e.key(7)
        #expect(outcome == .rebound(0))
        #expect(e.bindings[0].keyCode == 7 && e.bindings[0].label == "X")
        #expect(e.bindings[0].point == z.point)
    }

    @Test func deleteRemovesTheSelectedMarkerOnly() {
        var e = editor([z])
        let idle = e.key(KeymapEditor.delete)
        #expect(idle == .none && e.bindings.count == 1)
        e.click(x: 180, y: 320)
        let removed = e.key(KeymapEditor.delete)
        #expect(removed == .removed && e.bindings.isEmpty && e.selected == nil)
    }

    @Test func escapeCancelsThenExits() {
        var e = editor([z])
        e.click(x: 10, y: 10)
        let cancelled = e.key(KeymapEditor.escape)
        #expect(cancelled == .cancelled && e.pending == nil)
        let exit = e.key(KeymapEditor.escape)
        #expect(exit == .exit)
    }

    @Test func duplicateReservedAndFullAreRejectedWithoutChange() {
        var e = editor([z])
        e.click(x: 10, y: 10)
        let duplicate = e.key(6)
        #expect(duplicate == .rejected(.duplicate) && e.pending != nil && e.bindings.count == 1)
        let modifier = e.key(55)
        #expect(modifier == .rejected(.reserved))
        var full = editor((0..<8).map { .init(keyCode: UInt16($0), label: "k", point: .init(x: 0.5, y: 0.5)) })
        full.click(x: 10, y: 10)
        let overflow = full.key(20)
        #expect(overflow == .rejected(.full) && full.bindings.count == 8)
    }

    @Test func clicksOutsideTheViewAreClampedAndRebuildIntoAValidProfile() throws {
        var e = editor()
        e.click(x: -50, y: 9999)
        #expect(e.pending == NormalizedPoint(x: 0, y: 1))
        _ = e.key(0)
        #expect(try e.profile().bindings.count == 1)
    }

    @Test func labelsCoverCommonKeysWithAFallback() {
        #expect(KeyLabel.name(6) == "Z" && KeyLabel.name(49) == "Space" && KeyLabel.name(126) == "↑")
        #expect(KeyLabel.name(120) == "Key120")
    }
}
