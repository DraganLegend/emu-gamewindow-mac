import Foundation
import GRPCCore
import InputCore

enum TouchClient {
    static let touchMethod = "/android.emulation.control.EmulatorController/sendTouch"
    static func send<Transport: ClientTransport>(
        using client: GRPCClient<Transport>, contact: TouchContact, token: String
    ) async -> StatusOutcome {
        guard ContactLimits.game.contactIDs.contains(contact.id), (0..<4096).contains(contact.x),
              (0..<4096).contains(contact.y), [0, 512].contains(contact.pressure),
              !token.isEmpty, token.utf8.count <= 16384,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return .init(rpcAttempted: false, rpcCode: nil, booted: nil, localError: "invalid_touch_request")
        }
        var touch = Android_Emulation_Control_Touch()
        touch.identifier = contact.id; touch.x = contact.x; touch.y = contact.y
        touch.pressure = contact.pressure // Default expiration; never NEVER_EXPIRE.
        var event = Android_Emulation_Control_TouchEvent()
        event.display = 0; event.touches = [touch]
        var options = CallOptions.defaults
        options.timeout = .milliseconds(3000); options.waitForReady = false
        options.maxRequestMessageBytes = 1024 * 1024
        options.maxResponseMessageBytes = 1024 * 1024
        do {
            let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
            _ = try await controller.sendTouch(event, metadata: ["authorization": "Bearer \(token)"], options: options)
            return .init(rpcAttempted: true, rpcCode: 0, booted: nil, localError: nil)
        } catch let error as RPCError {
            return .init(rpcAttempted: true, rpcCode: error.code.rawValue, booted: nil,
                         localError: nil, diagnostic: StatusDiagnostic.classify(error))
        } catch {
            return .init(rpcAttempted: true, rpcCode: nil, booted: nil, localError: "client_failure")
        }
    }
}
