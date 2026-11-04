import Darwin
import Foundation

/// Disk thresholds. The AVD's userdata image only grows,
/// up to `disk.dataPartition.size`; the lines move up with what it may still
/// take. Mirrors `scripts/space_policy.py` — keep both in step.
///   stop = AVD remaining growth + 8 GiB   (below: refuse / end play normally)
///   warn = AVD remaining growth + 15 GiB  (below: only warn)
/// If the AVD numbers cannot be read (no AVD yet), the lines assume 12 GiB of
/// growth: stop 20 GiB, warn 27 GiB.
struct SpacePolicy: Equatable, Sendable {
    static let gib: UInt64 = 1024 * 1024 * 1024
    static let stopMargin: UInt64 = 8 * gib
    static let warnMargin: UInt64 = 15 * gib
    static let fallbackStop: UInt64 = 20 * gib
    static let fallbackWarn: UInt64 = 27 * gib
    static var avdDirectory: String { RuntimeDiscovery.project + "/.runtime/avd/" + RuntimeDiscovery.avd + ".avd" }

    enum Level: String, Codable, Sendable { case ok, warn, stop }

    let freeBytes: UInt64
    let avdMaxBytes: UInt64?
    let avdCurrentBytes: UInt64?

    var avdRemainingBytes: UInt64? {
        guard let max = avdMaxBytes, let current = avdCurrentBytes else { return nil }
        return max > current ? max - current : 0
    }
    var stopBytes: UInt64 { avdRemainingBytes.map { $0 + Self.stopMargin } ?? Self.fallbackStop }
    var warnBytes: UInt64 { avdRemainingBytes.map { $0 + Self.warnMargin } ?? Self.fallbackWarn }
    var level: Level { freeBytes < stopBytes ? .stop : freeBytes < warnBytes ? .warn : .ok }
    var usesFallback: Bool { avdRemainingBytes == nil }

    /// `disk.dataPartition.size` from config.ini (bytes, or with a K/M/G suffix).
    static func dataPartitionBytes(_ configText: String) -> UInt64? {
        for line in configText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "disk.dataPartition.size" else { continue }
            var text = parts[1].uppercased()
            var unit: UInt64 = 1
            // Same order as space_policy.py: two-letter suffixes first.
            for (suffix, factor) in [("GB", gib), ("MB", 1024 * 1024), ("KB", 1024), ("G", gib), ("M", 1024 * 1024), ("K", 1024)]
            where text.hasSuffix(suffix) {
                unit = factor; text.removeLast(suffix.count); break
            }
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
                  let value = UInt64(text), value > 0, value <= UInt64.max / unit else { return nil }
            return value * unit
        }
        return nil
    }

    /// Allocated bytes of one regular file, never following a link.
    static func allocated(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_blocks) * 512
    }

    static func current(project: String = RuntimeDiscovery.project, avd: String = avdDirectory) -> SpacePolicy {
        var fs = statvfs()
        let free = statvfs(project, &fs) == 0 ? UInt64(fs.f_bavail) * UInt64(fs.f_frsize) : 0
        let config = FileManager.default.contents(atPath: avd + "/config.ini").map { String(decoding: $0, as: UTF8.self) }
        return .init(freeBytes: free, avdMaxBytes: config.flatMap(dataPartitionBytes),
                     avdCurrentBytes: allocated(avd + "/userdata-qemu.img.qcow2"))
    }

    static func gibText(_ bytes: UInt64) -> String { String(format: "%.1f GiB", Double(bytes) / Double(gib)) }

    var summary: String {
        let label = ["ok": "充足", "warn": "接近警告線", "stop": "低於停止線"][level.rawValue] ?? "?"
        return "空間：\(label)｜空閒 \(Self.gibText(freeBytes))，警告線 \(Self.gibText(warnBytes))，停止線 \(Self.gibText(stopBytes))"
    }
}
