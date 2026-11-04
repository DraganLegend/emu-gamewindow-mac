import Darwin
import Foundation

/// Lists regenerable items under `.runtime` and `.build` and, only when the
/// user runs `egw clean --apply`, moves them to the macOS Trash (never a
/// permanent delete, never emptying the Trash). Only a few directories are
/// read and only exact name patterns match; anything the README or docs
/// mention is kept. The AVD, SDK, Android user data, keymaps and screenshots
/// never match a pattern.
enum SpaceCleaner {
    enum Category: String, Codable, Sendable, CaseIterable {
        case appArchive, testRun, emulatorLog, playReport, download, buildProduct, frameMap

        var label: String {
            switch self {
            case .appArchive: return "舊 App 封裝"
            case .testRun: return "建置／測試紀錄"
            case .emulatorLog: return "Emulator log"
            case .playReport: return "遊玩報告"
            case .download: return "安裝用壓縮檔"
            case .buildProduct: return "建置產物（可重建）"
            case .frameMap: return "遺留的畫面映射檔"
            }
        }
    }

    struct Item: Equatable, Sendable {
        let path: String
        let category: Category
        let bytes: UInt64
        let device: dev_t
        let inode: ino_t
    }

    struct Plan: Sendable {
        var items: [Item] = []
        /// Matched a pattern but a document mentions it: kept as evidence.
        var referenced: [String] = []
        var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    }

    static let keepAppArchives = 2
    static let keepRunsPerStage = 10
    static let keepLogs = 10
    static let keepPlayReports = 30
    /// Run directories written by scripts/build.py.
    static let stages: Set<String> = ["build", "test", "app"]

    // MARK: Patterns

    private static func digits(_ text: Substring, _ count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// "<prefix>YYYYMMDD-HHMMSS-ffffff<suffix>" -> the stamp, else nil.
    static func stamp(_ name: String, prefix: String, suffix: String, micro: Bool = true) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let core = name.dropFirst(prefix.count).dropLast(suffix.count)
        let parts = core.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == (micro ? 3 : 2), digits(parts[0], 8), digits(parts[1], 6),
              !micro || digits(parts[2], 6) else { return nil }
        return String(core)
    }

    /// A run directory "<stage>-<stamp>" with a known stage, else nil.
    static func runStage(_ name: String) -> String? {
        for stage in stages.sorted(by: { $0.count > $1.count })
        where stamp(name, prefix: stage + "-", suffix: "") != nil { return stage }
        return nil
    }

    // MARK: Filesystem

    private struct Entry { let name: String; let path: String; let isDirectory: Bool; let modified: Double; let device: dev_t; let inode: ino_t }

    /// Direct children that are real (non-link) directories or regular files we own.
    private static func entries(_ directory: String) -> [Entry] {
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name in
            let path = directory + "/" + name
            var child = stat()
            guard lstat(path, &child) == 0, child.st_uid == getuid() else { return nil }
            let type = child.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return nil }   // never a symlink
            return Entry(name: name, path: path, isDirectory: type == S_IFDIR,
                         modified: Double(child.st_mtimespec.tv_sec), device: child.st_dev, inode: child.st_ino)
        }
    }

    /// Allocated size without following links.
    static func size(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        var total = UInt64(info.st_blocks) * 512
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: path) else { return total }
        while let relative = walker.nextObject() as? String {
            var child = stat()
            if lstat(path + "/" + relative, &child) == 0 { total += UInt64(child.st_blocks) * 512 }
        }
        return total
    }

    /// Texts whose mentions protect an item: docs, READMEs, project rules.
    static func referenceTexts(root: String) -> [String] {
        var files = [root + "/README.md"]
        let docs = root + "/docs"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: docs)) ?? [] where name.hasSuffix(".md") {
            files.append(docs + "/" + name)
        }
        return files.compactMap { FileManager.default.contents(atPath: $0).map { String(decoding: $0, as: UTF8.self) } }
    }

    // MARK: Plan

    static func plan(root: String = RuntimeDiscovery.project, includeBuild: Bool,
                     references: [String]? = nil) -> Plan {
        let texts = references ?? referenceTexts(root: root)
        let build = root + "/.runtime/state"
        var picked: [(Entry, Category)] = []

        // Previous app bundles kept by scripts/package_app.py: keep the newest few.
        let archives = entries(build + "/app").filter { $0.isDirectory && stamp($0.name, prefix: "App-build-", suffix: ".app") != nil }
        for entry in archives.sorted(by: { $0.name > $1.name }).dropFirst(keepAppArchives) { picked.append((entry, .appArchive)) }

        // Build/test run directories: keep the newest per stage.
        let top = entries(build)
        let runs = Dictionary(grouping: top.filter { $0.isDirectory && runStage($0.name) != nil }) { runStage($0.name)! }
        for (_, group) in runs {
            for entry in group.sorted(by: { $0.name > $1.name }).dropFirst(keepRunsPerStage) { picked.append((entry, .testRun)) }
        }

        // Play reports: json + stderr pairs share a stamp; keep the newest stamps.
        let reports = top.filter { !$0.isDirectory && (stamp($0.name, prefix: "play-", suffix: ".json", micro: false) != nil
                                                     || stamp($0.name, prefix: "play-", suffix: ".stderr.txt", micro: false) != nil) }
        let reportStamps = Set(reports.map { String($0.name.dropFirst("play-".count).prefix(15)) }).sorted(by: >)
        let keptStamps = Set(reportStamps.prefix(keepPlayReports))
        for entry in reports where !keptStamps.contains(String(entry.name.dropFirst("play-".count).prefix(15))) {
            picked.append((entry, .playReport))
        }

        // Emulator logs: keep the newest by modification time.
        let logs = entries(root + "/.runtime/logs").filter { !$0.isDirectory && $0.name.hasSuffix(".log") }
        for entry in logs.sorted(by: { ($0.modified, $0.name) > ($1.modified, $1.name) }).dropFirst(keepLogs) {
            picked.append((entry, .emulatorLog))
        }

        // Frame mappings left by a game window that did not exit normally (its PID is gone).
        for entry in top where !entry.isDirectory && entry.name.hasPrefix("frames-") && entry.name.hasSuffix(".raw") {
            let digits = entry.name.dropFirst("frames-".count).dropLast(".raw".count)
            if let pid = Int32(digits), String(pid) == digits, pid > 1, kill(pid, 0) != 0, errno == ESRCH {
                picked.append((entry, .frameMap))
            }
        }

        // Installer archives already unpacked into android-sdk.
        for entry in entries(root + "/.runtime/downloads") where !entry.isDirectory && entry.name.hasSuffix(".zip") {
            picked.append((entry, .download))
        }

        // Rebuildable offline; dependency checkouts and package caches are never listed.
        if includeBuild {
            for entry in entries(root + "/.build") where entry.isDirectory && entry.name == "arm64-apple-macosx" {
                picked.append((entry, .buildProduct))
            }
        }

        var result = Plan()
        for (entry, category) in picked {
            // Build products are never evidence; their fixed names may appear in docs.
            if category != .buildProduct, texts.contains(where: { $0.contains(entry.name) }) {
                result.referenced.append(entry.path); continue
            }
            result.items.append(.init(path: entry.path, category: category, bytes: size(entry.path),
                                      device: entry.device, inode: entry.inode))
        }
        result.items.sort { ($0.category.rawValue, $0.path) < ($1.category.rawValue, $1.path) }
        result.referenced.sort()
        return result
    }

    // MARK: Apply

    struct ApplyResult: Sendable { var moved = 0; var movedBytes: UInt64 = 0; var skipped: [String] = [] }

    /// Moves each planned item to the Trash after re-checking it is the same
    /// non-link entry that was planned. One explicit path per call; no retry.
    static func apply(_ plan: Plan, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> ApplyResult {
        var result = ApplyResult()
        for item in plan.items {
            var info = stat()
            let type = lstat(item.path, &info) == 0 ? info.st_mode & S_IFMT : 0
            guard type == S_IFDIR || type == S_IFREG, info.st_dev == item.device, info.st_ino == item.inode,
                  info.st_uid == getuid() else { result.skipped.append(item.path); continue }
            do {
                try trash(URL(fileURLWithPath: item.path))
                result.moved += 1; result.movedBytes += item.bytes
            } catch { result.skipped.append(item.path) }
        }
        return result
    }

    // MARK: Reports

    static func report(_ plan: Plan, root: String) -> [String: Any] {
        var categories: [String: Any] = [:]
        for category in Category.allCases {
            let items = plan.items.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            categories[category.rawValue] = ["label": category.label, "count": items.count,
                                             "bytes": items.reduce(UInt64(0)) { $0 + $1.bytes }]
        }
        let relative = { (path: String) in path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path }
        return ["operation": "clean", "bytes": plan.bytes, "count": plan.items.count,
                "categories": categories, "items": plan.items.map { relative($0.path) },
                "keptAsEvidence": plan.referenced.map(relative)]
    }
}

/// `space`: read-only overview — thresholds, the AVD and what `egw clean` could move.
enum SpaceReport {
    static func report(policy: SpacePolicy, plan: SpaceCleaner.Plan) -> [String: Any] {
        var object: [String: Any] = [
            "operation": "space", "level": policy.level.rawValue, "freeBytes": policy.freeBytes,
            "stopBytes": policy.stopBytes, "warnBytes": policy.warnBytes, "fallback": policy.usesFallback,
            "summary": policy.summary, "cleanableBytes": plan.bytes, "cleanableCount": plan.items.count,
            "keptAsEvidence": plan.referenced.count,
        ]
        object["avdCurrentBytes"] = policy.avdCurrentBytes ?? 0
        object["avdMaxBytes"] = policy.avdMaxBytes ?? 0
        object["avdRemainingBytes"] = policy.avdRemainingBytes ?? 0
        var byCategory: [String: UInt64] = [:]
        for item in plan.items { byCategory[item.category.rawValue, default: 0] += item.bytes }
        object["cleanableByCategory"] = byCategory
        return object
    }
}
