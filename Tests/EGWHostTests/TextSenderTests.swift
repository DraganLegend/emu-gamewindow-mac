import Testing
@testable import EGWHost

@Suite("In-window typing via guest clipboard")
struct TextSenderTests {
    @Test func validatesText() {
        #expect(TextSender.validated("  你好，一起打王嗎？ ") == "你好，一起打王嗎？")
        #expect(TextSender.validated("gg wp") == "gg wp")
        #expect(TextSender.validated("   ") == nil)
        #expect(TextSender.validated("") == nil)
        #expect(TextSender.validated("line1\nline2") == nil)
        #expect(TextSender.validated("tab\there") == nil)
        #expect(TextSender.validated(String(repeating: "字", count: 500)) != nil)
        #expect(TextSender.validated(String(repeating: "字", count: 501)) == nil)
    }

    @Test func pasteIsCtrlVBalanced() {
        let steps = TextSender.pasteSequence()
        #expect(steps.map(\.code) == [29, 47, 47, 29])
        #expect(steps.map(\.down) == [true, true, false, false])
    }

    @Test func tokenAllowsWriteButNotReadOfClipboard() throws {
        let key = SessionKey()
        #expect(throws: Never.self) { _ = try key.token(now: 1_800_000_000, audiences: [TextSender.clipboardMethod]) }
        #expect(throws: Never.self) { _ = try key.token(now: 1_800_000_000, audiences: [TextSender.keyMethod]) }
        #expect(throws: SessionFailure.self) {
            _ = try key.token(now: 1_800_000_000, audiences: ["/android.emulation.control.EmulatorController/getClipboard"])
        }
        #expect(throws: SessionFailure.self) {
            _ = try key.token(now: 1_800_000_000, audiences: ["/android.emulation.control.EmulatorController/streamClipboard"])
        }
    }
}
