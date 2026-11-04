import Darwin
import Foundation

/// Machine-specific settings.
/// Read from `<project>/egw.config.json`; every key is optional and falls back
/// to `defaults`. The file must be a regular file owned by this user and not
/// writable by group/others, otherwise it is ignored (and `problem` says why),
/// which leaves a generic AVD name that matches no running instance.
struct HostConfig: Codable, Equatable, Sendable {
    var avd: String
    var grpcPort: Int
    var consolePort: Int
    var bundleIdentifier: String
    var appName: String

    static let defaults = HostConfig(avd: "egw_api35_arm64", grpcPort: 8554, consolePort: 5554,
                                     bundleIdentifier: "local.egw-launcher", appName: "EmuGameWindow")
    static let fileName = "egw.config.json"

    private enum CodingKeys: String, CodingKey { case avd, grpcPort, consolePort, bundleIdentifier, appName }

    init(avd: String, grpcPort: Int, consolePort: Int, bundleIdentifier: String, appName: String) {
        self.avd = avd; self.grpcPort = grpcPort; self.consolePort = consolePort
        self.bundleIdentifier = bundleIdentifier; self.appName = appName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self.defaults
        avd = try c.decodeIfPresent(String.self, forKey: .avd) ?? d.avd
        grpcPort = try c.decodeIfPresent(Int.self, forKey: .grpcPort) ?? d.grpcPort
        consolePort = try c.decodeIfPresent(Int.self, forKey: .consolePort) ?? d.consolePort
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? d.bundleIdentifier
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? d.appName
    }

    /// Nil when every value is safe to put into paths, command lines and plists.
    var invalidReason: String? {
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(avd, "^[A-Za-z0-9._-]{1,64}$") else { return "avd" }
        guard (1024...65535).contains(grpcPort) else { return "grpcPort" }
        // The Emulator console port is even, 5554...5682; adb uses the next one.
        guard (5554...5682).contains(consolePort), consolePort % 2 == 0 else { return "consolePort" }
        guard grpcPort != consolePort, grpcPort != consolePort + 1 else { return "grpcPort" }
        guard matches(bundleIdentifier, "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$"), bundleIdentifier.count <= 128 else {
            return "bundleIdentifier"
        }
        guard !appName.isEmpty, appName.count <= 40, !appName.contains("/"), !appName.contains(":"),
              appName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return "appName" }
        return nil
    }

    struct Loaded: Sendable, Equatable {
        let config: HostConfig
        /// Why the file was ignored; nil when it was used or absent.
        let problem: String?
    }

    static func load(project: String) -> Loaded {
        let path = project + "/" + fileName
        var info = stat()
        guard lstat(path, &info) == 0 else { return .init(config: defaults, problem: nil) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_size <= 4096 else { return .init(config: defaults, problem: "unsafe_file") }
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(HostConfig.self, from: data) else {
            return .init(config: defaults, problem: "unreadable")
        }
        if let reason = config.invalidReason { return .init(config: defaults, problem: "invalid_" + reason) }
        return .init(config: config, problem: nil)
    }
}

/// Where this project lives, without hard-coding a user's home directory.
enum HostPaths {
    /// Resolution order: `EGW_PROJECT`, the app's `EGWProjectRoot` (written at
    /// packaging), then the nearest parent of the executable or the working
    /// directory that looks like this project. Empty when nothing matches.
    static let project: String = resolveProject(
        environment: ProcessInfo.processInfo.environment["EGW_PROJECT"],
        bundleRoot: Bundle.main.object(forInfoDictionaryKey: "EGWProjectRoot") as? String,
        executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
        workingDirectory: FileManager.default.currentDirectoryPath)

    static let home = NSHomeDirectory()
    /// The Emulator writes its discovery files here (per user, not per project).
    static let running = home + "/Library/Caches/TemporaryItems/avd/running"
    static let loaded = HostConfig.load(project: project)
    static var config: HostConfig { loaded.config }

    static func looksLikeProject(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path + "/scripts/egw")
            && FileManager.default.fileExists(atPath: path + "/Package.swift")
    }

    static func resolveProject(environment: String?, bundleRoot: String?, executable: String?,
                               workingDirectory: String?, check: (String) -> Bool = looksLikeProject) -> String {
        for explicit in [environment, bundleRoot] {
            if let explicit, explicit.hasPrefix("/"), check(explicit) {
                return URL(fileURLWithPath: explicit).standardizedFileURL.path
            }
        }
        for start in [executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, workingDirectory] {
            guard var path = start, path.hasPrefix("/") else { continue }
            while path != "/" && !path.isEmpty {
                if check(path) { return path }
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
        return ""
    }
}
