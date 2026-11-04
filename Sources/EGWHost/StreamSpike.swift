import Darwin
import Dispatch
import Foundation
import GRPCCore

// Replan 20261101 step 1 (headless half): measure what streamScreenshot delivers
// over loopback gRPC. Receives frames only; never sends touch, key or any
// state-changing RPC. Frames are counted and discarded, never written to disk.
struct StreamSpikeOptions: Sendable {
    let session: String
    let seconds: Int
    let width: Int
    let height: Int
    let gameInUse: Bool
    /// Fast path: `file:///` handle of a mapping the Emulator writes frames into,
    /// and its size. nil keeps pixels in the gRPC reply.
    var mmapHandle: String? = nil
    var mmapCapacity: Int? = nil

    static func parse(_ args: [String]) throws -> Self {
        guard args.first == "stream-spike" else { throw ProbeOptions.invalid("stream-spike 語法不合法。") }
        var values: [String: String] = [:]
        var gameInUse = false
        var index = 1
        while index < args.count {
            if args[index] == "--game-in-use" {
                guard !gameInUse else { throw ProbeOptions.invalid("選項不可重複。") }
                gameInUse = true; index += 1; continue
            }
            guard ["--session", "--seconds", "--width", "--height"].contains(args[index]),
                  values[args[index]] == nil, index + 1 < args.count else {
                throw ProbeOptions.invalid("stream-spike 選項不合法或重複；請勿透過命令列提供憑證。")
            }
            values[args[index]] = args[index + 1]; index += 2
        }
        guard let session = values["--session"], let text = values["--seconds"],
              let seconds = Int(text), (5...300).contains(seconds),
              (values["--width"] == nil) == (values["--height"] == nil) else {
            throw ProbeOptions.invalid("stream-spike 需要 --session、--seconds 5～300；--width／--height 須成對。")
        }
        let width = Int(values["--width"] ?? "0"), height = Int(values["--height"] ?? "0")
        guard let width, let height,
              (width == 0 && height == 0) || ((64...2048).contains(width) && (64...2048).contains(height)) else {
            throw ProbeOptions.invalid("width／height 必須介於 64～2048。")
        }
        return .init(session: session, seconds: seconds, width: width, height: height, gameInUse: gameInUse)
    }
}

struct StreamSummary: Encodable, Sendable, Equatable {
    let frames: Int
    let invalidFrames: Int
    let droppedFrames: Int
    let seqRegressions: Int
    let width: Int
    let height: Int
    let rotation: Int
    let bytes: Int
    let seconds: Double
    let fps: Double
    let intervalMsP50: Double
    let intervalMsP95: Double
    let intervalMsMax: Double
    let latencyMsP50: Double
    let latencyMsP95: Double
}

// Pure accumulator so the arithmetic is testable without an Emulator.
struct StreamStats: Sendable {
    static let sampleLimit = 100_000
    private(set) var frames = 0
    private(set) var invalidFrames = 0
    private(set) var droppedFrames = 0
    private(set) var seqRegressions = 0
    private(set) var bytes = 0
    private var width = 0, height = 0, rotation = 0
    private var lastSeq: UInt32?
    private var lastArrivalNs: UInt64?
    private var firstArrivalNs: UInt64?
    private var lastArrivalForSpan: UInt64 = 0
    private var intervalsMS: [Double] = []
    private var latenciesMS: [Double] = []

    mutating func record(seq: UInt32, emulatorUs: UInt64, wallUs: UInt64, arrivalNs: UInt64,
                         width: Int, height: Int, rotation: Int, payloadBytes: Int) {
        frames += 1
        bytes += payloadBytes
        self.width = width; self.height = height; self.rotation = rotation
        if width <= 0 || height <= 0 || payloadBytes != width * height * 4 { invalidFrames += 1 }
        if let last = lastSeq {
            if seq > last { droppedFrames += Int(seq - last) - 1 } else { seqRegressions += 1 }
        }
        lastSeq = seq
        if firstArrivalNs == nil { firstArrivalNs = arrivalNs }
        if let previous = lastArrivalNs, arrivalNs >= previous, intervalsMS.count < Self.sampleLimit {
            intervalsMS.append(Double(arrivalNs - previous) / 1_000_000)
        }
        lastArrivalNs = arrivalNs; lastArrivalForSpan = arrivalNs
        // Same host clock for the Emulator estimate and the client; clamp skew at 0.
        if emulatorUs > 0, latenciesMS.count < Self.sampleLimit {
            latenciesMS.append(wallUs >= emulatorUs ? Double(wallUs - emulatorUs) / 1000 : 0)
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    func summary() -> StreamSummary {
        let span = firstArrivalNs.map { Double(lastArrivalForSpan - $0) / 1_000_000_000 } ?? 0
        return .init(
            frames: frames, invalidFrames: invalidFrames, droppedFrames: droppedFrames,
            seqRegressions: seqRegressions, width: width, height: height, rotation: rotation, bytes: bytes,
            seconds: Self.rounded(span), fps: span > 0 ? Self.rounded(Double(frames - 1) / span) : 0,
            intervalMsP50: Self.rounded(Self.percentile(intervalsMS, 0.5)),
            intervalMsP95: Self.rounded(Self.percentile(intervalsMS, 0.95)),
            intervalMsMax: Self.rounded(intervalsMS.max() ?? 0),
            latencyMsP50: Self.rounded(Self.percentile(latenciesMS, 0.5)),
            latencyMsP95: Self.rounded(Self.percentile(latenciesMS, 0.95)))
    }
}

struct StreamSpikeReport: Encodable, Sendable {
    var phase = "stream-spike"
    var transportCompleted = false
    var instanceVerified = false
    var keyCreated = false
    var keyLoaded = false
    var keyFileRemoved = false
    var keyRevoked = false
    var gameInUse = false
    var requestedSeconds = 0
    var crossedTokenExpiry = false
    var streamEndedEarly = false
    var summary: StreamSummary?
    var clientCPUSeconds: Double?
    var clientMaxRSSMiB: Double?
    var error: String?
    var rpcCode: Int?
    var rpcMessage: String?
    var diagnostic: StatusDiagnostic?
    // Fixed: this command has no input path at all.
    let inputSent = false
    let framesStored = false
}

actor StreamAudit {
    var stats = StreamStats()
    /// With MMAP the reply has no pixels: a frame counts as delivered when it fits the mapping.
    func record(_ image: Android_Emulation_Control_Image, arrivalNs: UInt64, wallUs: UInt64, mmapCapacity: Int? = nil) {
        let width = Int(image.format.width), height = Int(image.format.height)
        let payload = mmapCapacity.map { image.image.isEmpty && width * height * 4 <= $0 ? width * height * 4 : 0 }
            ?? image.image.count
        stats.record(seq: image.seq, emulatorUs: image.timestampUs, wallUs: wallUs, arrivalNs: arrivalNs,
                     width: width, height: height,
                     rotation: image.format.rotation.rotation.rawValue, payloadBytes: payload)
    }
    func snapshot() -> StreamStats { stats }
}

enum StreamSpike {
    static let streamMethod = "/android.emulation.control.EmulatorController/streamScreenshot"
    static let verifyIntervalNs: UInt64 = 5_000_000_000
    static let tokenLifetimeSeconds = 120

    /// Diagnostic only: keep a short printable-ASCII server message, and drop
    /// anything that could carry a credential. Never used by game-view.
    static func safeMessage(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 200,
              text.utf8.allSatisfy({ (32...126).contains($0) }),
              !text.contains("Bearer"), !text.contains("eyJ") else { return nil }
        return text
    }

    static func cpuAndRSS() -> (Double, Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        // ru_maxrss is bytes on macOS.
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime), Double(usage.ru_maxrss) / 1_048_576)
    }

    // Receive-only loop shared by the session command and the HTTP/2 tests.
    // Stops by returning from the response closure, which cancels the RPC.
    static func stream<Transport: ClientTransport>(
        using client: GRPCClient<Transport>, token: String, options: StreamSpikeOptions,
        audit: StreamAudit, verify: @escaping @Sendable () throws -> Void,
        onFrame: (@Sendable (Android_Emulation_Control_Image) async -> Void)? = nil
    ) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888; format.display = 0
        format.width = UInt32(options.width); format.height = UInt32(options.height)
        if let handle = options.mmapHandle {
            format.transport.channel = .mmap; format.transport.handle = handle
        }
        let capacity = options.mmapHandle == nil ? nil : options.mmapCapacity
        var call = CallOptions.defaults
        call.timeout = .seconds(options.seconds + 10); call.waitForReady = false
        // This transport derives the client's inbound payload limit from the
        // request limit, so both must cover a full RGBA frame (720x1280x4 = 3.7 MB).
        call.maxRequestMessageBytes = 16 * 1024 * 1024
        call.maxResponseMessageBytes = 16 * 1024 * 1024
        let start = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(options.seconds) * 1_000_000_000
        let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        let callOptions = call, request = format
        // A static screen yields no frames, so the stop time must not depend on frame arrival:
        // a timer task races the consumer and cancelling the loser ends the RPC.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Frame receipt drives what the player sees: run it at high priority.
            group.addTask(priority: .high) {
                try await controller.streamScreenshot(request, metadata: ["authorization": "Bearer \(token)"], options: callOptions) { response in
                    var lastVerify = DispatchTime.now().uptimeNanoseconds
                    for try await image in response.messages {
                        let now = DispatchTime.now().uptimeNanoseconds
                        await audit.record(image, arrivalNs: now, wallUs: UInt64(Date().timeIntervalSince1970 * 1_000_000),
                                           mmapCapacity: capacity)
                        await onFrame?(image)
                        if Task.isCancelled || now - start >= duration { break }
                        if now - lastVerify >= verifyIntervalNs { try verify(); lastVerify = now }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: duration)
                // Session still valid at the end; a change surfaces as the error below.
                try verify()
            }
            // First finisher wins. A consumer error (or a verify failure) is rethrown here.
            _ = try await group.next()
            group.cancelAll()
            // Cancellation of the loser is the normal stop, not a failure.
            while true {
                do { guard try await group.next() != nil else { break } } catch is CancellationError { continue }
                catch let error as RPCError where error.code == .cancelled { continue }
            }
        }
    }

    static func run(_ options: StreamSpikeOptions) async -> StreamSpikeReport {
        var report = StreamSpikeReport()
        report.gameInUse = options.gameInUse; report.requestedSeconds = options.seconds
        var file: OwnedPublicKey?
        var kid: String?
        var activePath: String?
        let audit = StreamAudit()
        let cpuBefore = cpuAndRSS().0
        do {
            try StatusSession.owned(options.session)
            let config = try JSONDecoder().decode(SessionConfig.self, from: Data(contentsOf: URL(fileURLWithPath: options.session)))
            let requireExit = !options.gameInUse
            let baseline = try StatusSession.validate(config, requireGameExited: requireExit)
            _ = try KeyStore.validate(config)
            let keyPath = config.jwks + "/egw-stream.jwk"
            guard !FileManager.default.fileExists(atPath: keyPath) else { throw SessionFailure.keyExistsOrInaccessible }
            report.instanceVerified = true
            let key = SessionKey(); kid = key.kid; activePath = config.active
            let publicFile = try OwnedPublicKey(path: keyPath, data: key.publicSet())
            file = publicFile; report.keyCreated = true
            report.keyLoaded = try await StatusSession.waitForKey(key.kid, active: config.active, present: true)
            guard report.keyLoaded else { throw SessionFailure.keyNotLoaded }
            let token = try key.token(now: Int(Date().timeIntervalSince1970), audiences: [streamMethod])
            let expectedKid = key.kid
            let transport = try StatusClient.makeTransport(host: "127.0.0.1", port: RuntimeDiscovery.grpcPort, security: "plaintext")
            let streamStart = DispatchTime.now().uptimeNanoseconds
            let duration = UInt64(options.seconds) * 1_000_000_000
            try await withGRPCClient(transport: transport) { client in
                @Sendable func verify() throws {
                    _ = try StatusSession.validate(config, expected: baseline, requireGameExited: requireExit)
                    try StatusSession.owned(keyPath)
                    var info = stat()
                    guard lstat(keyPath, &info) == 0, info.st_dev == publicFile.device,
                          info.st_ino == publicFile.inode else { throw SessionFailure.sessionChanged }
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config.active)))
                    guard let keys = (object as? [String: Any])?["keys"] as? [[String: Any]],
                          keys.count == 1, keys[0]["kid"] as? String == expectedKid else { throw SessionFailure.sessionChanged }
                }
                try verify(); try Task.checkCancellation()
                try await stream(using: client, token: token, options: options, audit: audit, verify: verify)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - streamStart
            report.crossedTokenExpiry = elapsed >= UInt64(tokenLifetimeSeconds) * 1_000_000_000
            report.streamEndedEarly = !Task.isCancelled && elapsed + 1_000_000_000 < duration
        } catch let error as RPCError {
            report.error = "rpc_failed"; report.rpcCode = error.code.rawValue
            report.rpcMessage = safeMessage(error.message)
            report.diagnostic = StatusDiagnostic.classify(error)
        } catch let error as SessionFailure { report.error = error.rawValue }
        catch is CancellationError { report.error = "cancelled" }
        catch { report.error = "local_failure" }
        let stats = await audit.snapshot()
        if stats.frames > 0 { report.summary = stats.summary() }
        let after = cpuAndRSS()
        report.clientCPUSeconds = ((after.0 - cpuBefore) * 100).rounded() / 100
        report.clientMaxRSSMiB = (after.1 * 10).rounded() / 10
        if report.error == nil && Task.isCancelled { report.error = "cancelled" }
        if let file, let kid, let activePath {
            // Await bounded cleanup even after an interrupt; no background job.
            let removed = await Task.detached { () -> (Bool, Bool) in
                do {
                    try file.remove()
                    return (true, (try? await StatusSession.waitForKey(kid, active: activePath, present: false)) ?? false)
                } catch { return (false, false) }
            }.value
            report.keyFileRemoved = removed.0; report.keyRevoked = removed.1
            if !removed.1 { report.error = SessionFailure.keyRevocationUnconfirmed.rawValue }
        }
        report.transportCompleted = report.error == nil && report.keyRevoked && (report.summary?.frames ?? 0) > 0
        return report
    }

    static func interruptible(_ options: StreamSpikeOptions) async -> StreamSpikeReport {
        let work = Task { await run(options) }
        let previousINT = signal(SIGINT, SIG_IGN), previousTERM = signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { work.cancel() }; source.resume(); return source
        }
        defer {
            for source in sources { source.cancel() }
            signal(SIGINT, previousINT); signal(SIGTERM, previousTERM)
        }
        return await work.value
    }
}
