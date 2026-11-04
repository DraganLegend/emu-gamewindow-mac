import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import SwiftProtobuf

// Only explicit allowlisted fields leave this boundary. In particular, neither
// server error messages/metadata nor Emulator hardware/guest config are exposed.
struct StatusOutcome: Codable, Sendable, Equatable {
    let rpcAttempted: Bool
    let rpcCode: Int?
    let booted: Bool?
    let localError: String?
    let diagnostic: StatusDiagnostic?

    init(rpcAttempted: Bool, rpcCode: Int?, booted: Bool?, localError: String?,
         diagnostic: StatusDiagnostic? = nil) {
        self.rpcAttempted = rpcAttempted
        self.rpcCode = rpcCode
        self.booted = booted
        self.localError = localError
        self.diagnostic = diagnostic
    }
}

// Fixed hints only. A matching server message is not proof of error origin.
// Never retain or encode the message, metadata or nested cause.
enum StatusDiagnostic: String, Codable, Sendable {
    case jwtTypeHeaderRejected = "jwt_type_header_rejected"
    case jwtSignatureInvalid = "jwt_signature_invalid"
    case jwtPayloadInvalid = "jwt_payload_invalid"
    case unclassified

    static func classify(_ error: RPCError) -> Self {
        guard error.code == .invalidArgument else { return .unclassified }
        switch error.message {
        case "invalid JWT; token has type header set, but validator not":
            return .jwtTypeHeaderRejected
        case "invalid JWT signature":
            return .jwtSignatureInvalid
        case "invalid JWT payload":
            return .jwtPayloadInvalid
        default:
            return .unclassified
        }
    }
}

enum StatusClient {
    // The one-shot session verifies instance and security before this factory.
    static func makeTransport(
        host: String, port: Int, security: String
    ) throws -> HTTP2ClientTransport.Posix {
        guard ["127.0.0.1", "::1"].contains(host),
              (1...65535).contains(port),
              ["tls", "plaintext"].contains(security) else {
            throw ProbeOptions.invalid("連線設定不合法。")
        }
        let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity =
            security == "tls" ? .tls : .plaintext
        // Empty service configuration: no configured retries or hedging.
        if host == "::1" {
            return try .init(
                target: .ipv6(address: host, port: port),
                transportSecurity: transportSecurity,
                serviceConfig: ServiceConfig()
            )
        }
        return try .init(
            target: .ipv4(address: host, port: port),
            transportSecurity: transportSecurity,
            serviceConfig: ServiceConfig()
        )
    }

    // Call exactly one generated getStatus method. The owner supplies an
    // already-running client with no retry policy. nil token is reserved for
    // the planned unauthenticated negative test, never an automatic fallback.
    static func query<Transport: ClientTransport>(
        using client: GRPCClient<Transport>,
        bearerToken: String?,
        timeoutMS: Int
    ) async -> StatusOutcome {
        guard (100...10000).contains(timeoutMS) else {
            return .init(rpcAttempted: false, rpcCode: nil, booted: nil, localError: "invalid_timeout")
        }
        var metadata: Metadata = [:]
        if let token = bearerToken {
            guard !token.isEmpty, token.utf8.count <= 16384,
                  token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                return .init(rpcAttempted: false, rpcCode: nil, booted: nil, localError: "invalid_credential")
            }
            metadata.addString("Bearer \(token)", forKey: "authorization")
        }
        var options = CallOptions.defaults
        options.timeout = .milliseconds(timeoutMS)
        options.waitForReady = false
        // Transport 2.11.0 also passes this setting to its response decoder.
        // Zero would reject every non-empty status response over HTTP/2.
        // The generated request is still google.protobuf.Empty (zero bytes).
        options.maxRequestMessageBytes = 1024 * 1024
        options.maxResponseMessageBytes = 1024 * 1024
        do {
            let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
            let response = try await controller.getStatus(
                Google_Protobuf_Empty(), metadata: metadata, options: options
            )
            return .init(rpcAttempted: true, rpcCode: 0, booted: response.booted, localError: nil)
        } catch let error as RPCError {
            return .init(rpcAttempted: true, rpcCode: error.code.rawValue, booted: nil,
                         localError: nil, diagnostic: StatusDiagnostic.classify(error))
        } catch {
            return .init(rpcAttempted: true, rpcCode: nil, booted: nil, localError: "client_failure")
        }
    }
}
