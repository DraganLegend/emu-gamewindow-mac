import Darwin
import Foundation
import GRPCCore

struct SessionConfig: Decodable, Sendable {
    let pid: Int32
    let project: String
    let discovery: String
    let jwks: String
    let active: String
    let verifiedAt: Double
    let usbDebuggingOff: Bool
    let gameExited: Bool
}

enum StatusSession {
    // Shared with Host HTTP/2 tests so the valid-only boundary is verified
    // with real call counts, without provisioning an Emulator session.
    static func owned(_ path: String, directory: Bool = false) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & 0o777) == (directory ? 0o700 : 0o600),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            throw SessionFailure.invalidSession
        }
    }

    static func fields(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    // Bounded local inspection; output is used for checks, never logged.
    static func inspect(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let until = Date().addingTimeInterval(2)
        while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw SessionFailure.sessionChanged }
        guard process.terminationStatus == 0 else { throw SessionFailure.sessionChanged }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// `maxAge` bounds how old the operator's confirmation may be. Long-running
    /// sessions re-check everything else in flight with `maxAge: nil`.
    static func validate(_ config: SessionConfig, expected: Data? = nil, requireGameExited: Bool = true,
                         maxAge: Double? = 600) throws -> Data {
        let root = RuntimeDiscovery.project, port = RuntimeDiscovery.grpcPort
        let running = RuntimeDiscovery.running
        let prefix = running + "/\(config.pid)/jwks/"
        let suffix = String(config.jwks.dropFirst(prefix.count))
        let age = Date().timeIntervalSince1970 - config.verifiedAt
        guard !root.isEmpty, config.project == root, config.pid > 1, age >= 0, maxAge.map({ age < $0 }) ?? true,
              config.usbDebuggingOff, (!requireGameExited || config.gameExited),
              config.discovery == running + "/pid_\(config.pid).ini",
              config.jwks.hasPrefix(prefix), UUID(uuidString: suffix) != nil,
              config.active == config.jwks + "/active.jwk", kill(config.pid, 0) == 0 else {
            throw SessionFailure.invalidSession
        }
        try owned(config.discovery)
        try owned(config.jwks, directory: true)
        try owned(config.active)
        let data = try Data(contentsOf: URL(fileURLWithPath: config.discovery))
        if let expected, expected != data { throw SessionFailure.sessionChanged }
        let values = fields(data)
        let avd = RuntimeDiscovery.avd
        guard values["avd.id"] == avd,
              values["avd.dir"] == root + "/.runtime/avd/" + avd + ".avd",
              values["grpc.port"] == String(port), values["grpc.jwks"] == config.jwks,
              values["grpc.jwk_active"] == config.active,
              values["grpc.allowlist"] == root + "/.runtime/android-sdk/emulator/lib/emulator_access.json",
              values["emulator.version"] == "37.2.12.0", values["grpc.token"] == nil,
              values["grpc.server_cert"] == nil else { throw SessionFailure.invalidSession }
        let command = try inspect("/bin/ps", ["-p", String(config.pid), "-o", "command="])
        guard command.hasPrefix(root + "/.runtime/android-sdk/emulator/"),
              command.contains("-avd " + avd), command.contains("-grpc \(port)"),
              command.contains("-grpc-use-jwt"), command.contains("-gpu host") else {
            throw SessionFailure.sessionChanged
        }
        let listener = try inspect("/usr/sbin/lsof", ["-nP", "-a", "-p", String(config.pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"])
        guard listener.split(separator: "\n").filter({ $0.hasPrefix("n") }) == ["n127.0.0.1:\(port)"] else {
            throw SessionFailure.sessionChanged
        }
        // Stop line: AVD remaining growth + 8 GiB (20 GiB if the AVD numbers are unreadable).
        let space = SpacePolicy.current()
        guard space.freeBytes > 0, space.level != .stop else {
            throw SessionFailure.invalidSession
        }
        return data
    }

    static func waitForKey(_ kid: String, active: String, present: Bool) async throws -> Bool {
        // Only local file observation; this does not retry any RPC.
        for _ in 0..<25 {
            try owned(active)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: active)))
            guard let keys = (object as? [String: Any])?["keys"] as? [[String: Any]] else {
                throw SessionFailure.invalidSession
            }
            if keys.contains(where: { $0["kid"] as? String == kid }) == present { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}
