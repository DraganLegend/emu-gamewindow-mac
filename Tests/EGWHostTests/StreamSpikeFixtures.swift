import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import SwiftProtobuf
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.
actor StreamRequests {
    var count = 0
    var lastFormat: Android_Emulation_Control_ImageFormat?
    var clientSeconds = 0.0
    func noteClient(_ seconds: Double) { clientSeconds = seconds }
    func add(_ format: Android_Emulation_Control_ImageFormat) { count += 1; lastFormat = format }
}

private struct StreamService: RegistrableRPCService {
    let requests: StreamRequests
    // nil frames: keep streaming until the client cancels.
    let frames: Int?
    var side = 64
    var idleAfter = false
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: Android_Emulation_Control_EmulatorController.Method.streamScreenshot.descriptor,
            deserializer: ProtobufDeserializer<Android_Emulation_Control_ImageFormat>(),
            serializer: ProtobufSerializer<Android_Emulation_Control_Image>()
        ) { request, _ in
            let request = try await ServerRequest(stream: request)
            guard request.metadata[stringValues: "authorization"].first(where: { _ in true }) == "Bearer SYNTHETIC_TOKEN",
                  request.message.format == .rgba8888, request.message.display == 0 else {
                throw RPCError(code: .invalidArgument, message: "SYNTHETIC_SECRET")
            }
            await requests.add(request.message)
            return StreamingServerResponse(of: Android_Emulation_Control_Image.self) { writer in
                var seq: UInt32 = 0
                while frames.map({ Int(seq) < $0 }) ?? true {
                    var image = Android_Emulation_Control_Image()
                    image.format.width = UInt32(side); image.format.height = UInt32(side)
                    image.image = Data(count: side * side * 4)
                    image.seq = seq
                    image.timestampUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                    try await writer.write(image)
                    seq += 1
                    try await Task.sleep(for: .milliseconds(20))
                }
                // A static screen: the stream stays open but silent.
                if idleAfter { try await Task.sleep(for: .seconds(12)) }
                return [:]
            }
        }
    }
}

func runStream(seconds: Int, frames: Int?, side: Int = 64, idle: Bool = false, token: String = "SYNTHETIC_TOKEN") async throws -> (StreamStats, StreamRequests, any Error) {
    let requests = StreamRequests()
    let audit = StreamAudit()
    let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
    let options = try StreamSpikeOptions.parse(["stream-spike", "--session", "/x", "--seconds", String(seconds)])
    let failure: (any Error)? = try await withGRPCServer(transport: transport, services: [StreamService(requests: requests, frames: frames, side: side, idleAfter: idle)]) { _ in
        let address = try await transport.listeningAddress
        guard let bound = address.ipv4, bound.host == "127.0.0.1" else { throw SessionFailure.invalidSession }
        let clientTransport = try StatusClient.makeTransport(host: bound.host, port: bound.port, security: "plaintext")
        return try await withGRPCClient(transport: clientTransport) { client -> (any Error)? in
            let began = Date()
            do {
                try await StreamSpike.stream(using: client, token: token, options: options, audit: audit, verify: {})
                await requests.noteClient(Date().timeIntervalSince(began)); return nil
            } catch { await requests.noteClient(Date().timeIntervalSince(began)); return error }
        }
    }
    return (await audit.snapshot(), requests, failure ?? CancellationError())
}

