import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing
@testable import EGWHost

actor Calls {
    var count = 0
    func add() { count += 1 }
}

// Synthetic service in memory only. It is not an Emulator security model.
struct MockStatusService: RegistrableRPCService {
    let calls: Calls
    var booted = false
    var delayMS = 0
    var error: RPCError.Code?
    var errorMessage = "SYNTHETIC_SECRET"
    var responseVersion = "SYNTHETIC_SECRET"

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: Android_Emulation_Control_EmulatorController.Method.getStatus.descriptor,
            deserializer: ProtobufDeserializer<Google_Protobuf_Empty>(),
            serializer: ProtobufSerializer<Android_Emulation_Control_EmulatorStatus>()
        ) { request, _ in
            let request = try await ServerRequest(stream: request)
            await calls.add()
            guard request.metadata[stringValues: "authorization"].first(where: { _ in true }) == "Bearer SYNTHETIC_TOKEN" else {
                throw RPCError(code: .unauthenticated, message: "SYNTHETIC_SECRET",
                               metadata: ["private": "SYNTHETIC_SECRET"])
            }
            if let error {
                throw RPCError(code: error, message: errorMessage,
                               metadata: ["private": "SYNTHETIC_SECRET"])
            }
            if delayMS > 0 { try await Task.sleep(for: .milliseconds(delayMS)) }
            var message = Android_Emulation_Control_EmulatorStatus()
            message.booted = booted
            message.version = responseVersion
            return StreamingServerResponse(
                single: ServerResponse(message: message, metadata: ["private": "SYNTHETIC_SECRET"])
            )
        }
    }
}

private func runMock(
    booted: Bool = false, token: String? = "SYNTHETIC_TOKEN",
    delayMS: Int = 0, timeoutMS: Int = 1000, error: RPCError.Code? = nil
) async throws -> (StatusOutcome, Int, Duration) {
    let calls = Calls()
    let pair = InProcessTransport()
    let (outcome, elapsed) = try await withGRPCServer(
        transport: pair.server,
        services: [MockStatusService(calls: calls, booted: booted, delayMS: delayMS, error: error)]
    ) { _ in
        try await withGRPCClient(transport: pair.client) { client in
            let start = ContinuousClock.now
            let result = await StatusClient.query(using: client, bearerToken: token, timeoutMS: timeoutMS)
            return (result, start.duration(to: .now))
        }
    }
    return (outcome, await calls.count, elapsed)
}

@Suite("Host-only generated getStatus contract")
struct StatusClientTests {
    @Test(arguments: [false, true])
    func preservesBooted(_ booted: Bool) async throws {
        let (result, calls, _) = try await runMock(booted: booted)
        #expect(result.rpcCode == 0)
        #expect(result.booted == booted)
        #expect(calls == 1)
        #expect(try encodeOutcome(result).contains("SYNTHETIC") == false)
    }

    @Test(arguments: [nil, "WRONG_TOKEN"] as [String?])
    func authFailureIsSanitized(_ token: String?) async throws {
        let (result, calls, _) = try await runMock(token: token)
        #expect(result.rpcCode == 16)
        #expect(result.booted == nil)
        #expect(calls == 1)
        #expect(try encodeOutcome(result).contains("SYNTHETIC") == false)
    }

    @Test
    func unavailableIsNotRetried() async throws {
        let (result, calls, _) = try await runMock(error: .unavailable)
        #expect(result.rpcCode == 14)
        #expect(result.booted == nil)
        #expect(calls == 1)
    }

    @Test
    func deadlineBoundsQuery() async throws {
        // Measure query return, not graceful teardown of the synthetic server.
        // This does not claim that a remote handler has stopped executing.
        let (result, calls, elapsed) = try await runMock(delayMS: 2000, timeoutMS: 100)
        #expect(result.rpcCode == 4)
        #expect(result.booted == nil)
        #expect(calls == 1)
        #expect(elapsed < .seconds(1))
    }

    @Test(arguments: ["", "bad\r\nheader", "bad token"])
    func rejectsMalformedCredential(_ token: String) async throws {
        // No connection task or server: validation must finish before an RPC.
        let client = GRPCClient(transport: InProcessTransport().client)
        let result = await StatusClient.query(using: client, bearerToken: token, timeoutMS: 1000)
        #expect(!result.rpcAttempted)
        #expect(result.localError == "invalid_credential")
        #expect(result.rpcCode == nil)
    }

    @Test
    func invalidTimeoutDoesNotSend() async throws {
        let client = GRPCClient(transport: InProcessTransport().client)
        let result = await StatusClient.query(using: client, bearerToken: "SYNTHETIC_TOKEN", timeoutMS: 0)
        #expect(!result.rpcAttempted)
        #expect(result.localError == "invalid_timeout")
        #expect(result.rpcCode == nil)
    }
}
