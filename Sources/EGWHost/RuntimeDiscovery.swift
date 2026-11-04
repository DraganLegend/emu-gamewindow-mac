import Darwin
import Foundation

/// find this project's running Emulator from its own discovery files and
/// build the session in memory, instead of a hand-written session JSON. The
/// result still goes through `StatusSession.validate` (AVD, version, ports,
/// JWT, loopback, file modes, capacity) before any key or RPC.
///
/// USB debugging OFF and the game state are the operator's statements; this
/// code cannot observe them, so callers pass them explicitly.
enum RuntimeDiscovery {
    // Machine-specific values come from HostConfig / egw.config.json (open-source plan, phase 1).
    static var project: String { HostPaths.project }
    static var running: String { HostPaths.running }
    static var avd: String { HostPaths.config.avd }
    static var grpcPort: Int { HostPaths.config.grpcPort }

    enum State: String, Codable, Sendable {
        /// No discovery file and no Emulator process for this AVD.
        case stopped
        /// An Emulator process for this AVD exists but has not written discovery yet.
        case starting
        /// Exactly one live instance with discovery for this AVD.
        case running
        /// Discovery exists but its process is gone (crashed or killed).
        case lost
        /// More than one candidate: refuse rather than guess.
        case ambiguous
    }

    struct Finding: Sendable, Equatable {
        let state: State
        let pid: Int32?
        let discovery: String?
        let jwks: String?
        let active: String?
    }

    /// One discovery file for this AVD (fields from the Emulator, not trusted yet).
    struct Candidate: Equatable, Sendable {
        let pid: Int32
        let path: String
        let jwks: String
        let active: String
    }

    static func candidates(in directory: String = running) -> [Candidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var result: [Candidate] = []
        for name in names.sorted() where name.hasPrefix("pid_") && name.hasSuffix(".ini") {
            let digits = name.dropFirst(4).dropLast(4)
            guard let pid = Int32(digits), pid > 1, String(pid) == digits else { continue }
            let path = directory + "/" + name
            var info = stat()
            // Regular, owner-only, ours, bounded: never follow a link or read a large file.
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  info.st_size < 64 * 1024, let data = FileManager.default.contents(atPath: path) else { continue }
            let values = StatusSession.fields(data)
            guard values["avd.id"] == avd, let jwks = values["grpc.jwks"], let active = values["grpc.jwk_active"] else { continue }
            result.append(.init(pid: pid, path: path, jwks: jwks, active: active))
        }
        return result
    }

    /// PIDs of Emulator processes whose command line names this AVD.
    static func emulatorPIDs() -> [Int32] {
        // Read to EOF before waiting: a full process list can exceed the pipe buffer.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return parseEmulatorPIDs(String(decoding: data, as: UTF8.self))
    }

    static func parseEmulatorPIDs(_ text: String) -> [Int32] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]),
                  parts[1].hasPrefix(project + "/.runtime/android-sdk/emulator/"),
                  parts[1].contains("-avd " + avd) else { return nil }
            return pid
        }
    }

    /// Pure decision from what is on disk and in the process table.
    static func classify(candidates: [Candidate], alive: (Int32) -> Bool, emulatorPIDs: [Int32]) -> Finding {
        let live = candidates.filter { alive($0.pid) }
        if live.count > 1 { return .init(state: .ambiguous, pid: nil, discovery: nil, jwks: nil, active: nil) }
        if let one = live.first {
            // Another Emulator for the same AVD besides the discovered one is not ours to pick.
            if emulatorPIDs.contains(where: { $0 != one.pid }) {
                return .init(state: .ambiguous, pid: nil, discovery: nil, jwks: nil, active: nil)
            }
            return .init(state: .running, pid: one.pid, discovery: one.path, jwks: one.jwks, active: one.active)
        }
        if emulatorPIDs.count > 1 { return .init(state: .ambiguous, pid: nil, discovery: nil, jwks: nil, active: nil) }
        if let pid = emulatorPIDs.first { return .init(state: .starting, pid: pid, discovery: nil, jwks: nil, active: nil) }
        if !candidates.isEmpty { return .init(state: .lost, pid: candidates.first?.pid, discovery: nil, jwks: nil, active: nil) }
        return .init(state: .stopped, pid: nil, discovery: nil, jwks: nil, active: nil)
    }

    static func find() -> Finding {
        classify(candidates: candidates(), alive: { kill($0, 0) == 0 }, emulatorPIDs: emulatorPIDs())
    }

    /// The in-memory session for a running instance. Throws unless exactly one
    /// instance is running; full validation is still the caller's next step.
    static func session(usbDebuggingOff: Bool, gameExited: Bool, finding: Finding = find()) throws -> SessionConfig {
        guard finding.state == .running, let pid = finding.pid, let discovery = finding.discovery,
              let jwks = finding.jwks, let active = finding.active else { throw SessionFailure.invalidSession }
        return SessionConfig(pid: pid, project: project, discovery: discovery, jwks: jwks, active: active,
                             verifiedAt: Date().timeIntervalSince1970,
                             usbDebuggingOff: usbDebuggingOff, gameExited: gameExited)
    }
}

/// `status`: a read-only answer from files and the process table. No key,
/// no RPC; "running" means discovered, not that Android finished booting.
enum RuntimeStatus {
    static func report(_ finding: Finding) -> [String: Any] {
        var object: [String: Any] = ["operation": "status", "state": finding.state.rawValue,
                                     "rpcAttempted": false, "avd": RuntimeDiscovery.avd]
        object["pid"] = finding.pid.map { Int($0) } ?? NSNull()
        return object
    }
    typealias Finding = RuntimeDiscovery.Finding

    static func exitCode(_ state: RuntimeDiscovery.State) -> Int32 {
        switch state {
        case .running: return 0
        case .stopped: return 3
        case .starting: return 4
        case .lost: return 5
        case .ambiguous: return 6
        }
    }
}
