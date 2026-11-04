import Foundation
import GRPCCore

/// Typed text for the game (Chinese included). gRPC `sendKey` only carries
/// printable ASCII, and the Emulator's own docs point to the clipboard for
/// text, so: write the text to the guest clipboard with `setClipboard`, then
/// press Ctrl+V as raw evdev keys. The guest clipboard is only written, never
/// read; the Mac pasteboard is not touched. The game's text box must already
/// be focused in Android. No retry: a failed step is reported, not repeated.
enum TextSender {
    static let clipboardMethod = "/android.emulation.control.EmulatorController/setClipboard"
    static let keyMethod = "/android.emulation.control.EmulatorController/sendKey"
    static let maximumCharacters = 500
    /// Linux evdev codes: KEY_LEFTCTRL and KEY_V.
    static let leftControl: Int32 = 29, keyV: Int32 = 47

    enum Failure: String, Error, Sendable { case invalidText, clipboard, paste }

    /// Trimmed, non-empty, bounded, single line; tabs/newlines/control characters refused.
    static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maximumCharacters,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    /// Ctrl down, V down, V up, Ctrl up — each a separate evdev key event.
    static func pasteSequence() -> [(code: Int32, down: Bool)] {
        [(leftControl, true), (keyV, true), (keyV, false), (leftControl, false)]
    }

    static func send<Transport: ClientTransport>(
        _ text: String, using client: GRPCClient<Transport>, token: (_ audience: String) -> String
    ) async -> Result<Void, Failure> {
        guard let text = validated(text) else { return .failure(.invalidText) }
        var options = CallOptions.defaults
        options.timeout = .milliseconds(3000); options.waitForReady = false
        options.maxRequestMessageBytes = 1024 * 1024; options.maxResponseMessageBytes = 1024 * 1024
        let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        var clip = Android_Emulation_Control_ClipData()
        clip.text = text
        do {
            _ = try await controller.setClipboard(clip, metadata: ["authorization": "Bearer \(token(clipboardMethod))"], options: options)
        } catch { return .failure(.clipboard) }
        // setClipboard is applied asynchronously on the Emulator's looper; give it a moment.
        try? await Task.sleep(for: .milliseconds(150))
        var pressed: [Int32] = []
        for step in pasteSequence() {
            var event = Android_Emulation_Control_KeyboardEvent()
            event.codeType = .evdev
            event.eventType = step.down ? .keydown : .keyup
            event.keyCode = step.code
            do {
                _ = try await controller.sendKey(event, metadata: ["authorization": "Bearer \(token(keyMethod))"], options: options)
                if step.down { pressed.append(step.code) } else { pressed.removeAll { $0 == step.code } }
            } catch {
                // Best effort: lift anything this call pressed, once each, so Ctrl is not left held.
                for code in pressed.reversed() {
                    var up = Android_Emulation_Control_KeyboardEvent()
                    up.codeType = .evdev; up.eventType = .keyup; up.keyCode = code
                    _ = try? await controller.sendKey(up, metadata: ["authorization": "Bearer \(token(keyMethod))"], options: options)
                }
                return .failure(.paste)
            }
        }
        return .success(())
    }
}
