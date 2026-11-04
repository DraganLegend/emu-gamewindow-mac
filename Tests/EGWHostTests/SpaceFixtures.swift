import Darwin
import Foundation
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.

struct CleanerFixtureResult {
    var planned: [String] = []          // relative paths
    var plannedBuild: [String] = []     // with --include-build, build products only
    var evidence: [String] = []
    var trashed: [String] = []
    var skipped: [String] = []
    var ok = false
}

/// Builds a fake project tree in a private temp directory, plans, applies with
/// a fake trash, then removes only what it created (each path explicitly).
func cleanerFixture() -> CleanerFixtureResult {
    var out = CleanerFixtureResult()
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    let root = base + "/egw-clean-\(UUID().uuidString)"
    var files: [String] = [], dirs: [String] = []
    func dir(_ rel: String) { let p = root + "/" + rel; mkdir(p, 0o700); dirs.append(p) }
    func file(_ rel: String, age: Int = 0) {
        let p = root + "/" + rel
        let fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0o600); if fd >= 0 { _ = write(fd, "x", 1); close(fd) }
        if age > 0 {
            var times = [timespec(tv_sec: time(nil) - age, tv_nsec: 0), timespec(tv_sec: time(nil) - age, tv_nsec: 0)]
            utimensat(AT_FDCWD, p, &times, 0)
        }
        files.append(p)
    }
    defer {
        for p in files.reversed() { unlink(p) }
        for p in dirs.reversed() { rmdir(p) }
    }
    mkdir(root, 0o700); dirs.append(root)
    for d in [".runtime", ".runtime/state", ".runtime/state/app", ".runtime/state/keymaps", ".runtime/logs",
              ".runtime/downloads", ".runtime/avd", ".runtime/screenshots", ".build", ".build/arm64-apple-macosx",
              ".build/checkouts", "docs"] { dir(d) }
    // Protected or non-matching: must never be planned.
    file(".runtime/avd/userdata-qemu.img.qcow2"); file(".runtime/state/keymap.json")
    file(".runtime/state/keymaps/raid.json"); file(".runtime/screenshots/EGW-20261101-000000-000.png")
    dir(".runtime/state/app/EmuGameWindow.app"); file(".build/checkouts/x")
    // App archives: keep newest 2.
    for s in ["20261101-221235-500517", "20261102-192646-622932", "20261103-100000-000000"] { dir(".runtime/state/app/App-build-\(s).app") }
    // 12 test runs: the 2 oldest planned (one is mentioned in a doc). One build run: kept.
    for i in 0..<12 { dir(".runtime/state/test-202611\(String(format: "%02d", i + 1))-000000-000000") }
    dir(".runtime/state/build-20261101-213428-932673")
    // A link that looks like a run must be ignored.
    symlink(root + "/.runtime/state/test-20261112-000000-000000", root + "/.runtime/state/test-20200101-000000-000000")
    files.append(root + "/.runtime/state/test-20200101-000000-000000")
    // 32 play stamps (json + stderr): the 2 oldest stamps planned.
    for i in 0..<32 {
        let s = "202611\(String(format: "%02d", i % 28 + 1))-\(String(format: "%02d", i / 28))0000"
        file(".runtime/state/play-\(s).json"); file(".runtime/state/play-\(s).stderr.txt")
    }
    // 12 logs: the 2 oldest by mtime planned.
    for i in 0..<12 { file(".runtime/logs/emu-\(i).log", age: (i + 1) * 3600) }
    file(".runtime/downloads/commandlinetools.zip")
    // Frame mappings: a dead PID's file is planned, our own (alive) is not.
    file(".runtime/state/frames-999999.raw"); file(".runtime/state/frames-\(getpid()).raw")
    // A doc mentions one old run: kept.
    let doc = "log: .runtime/state/test-20261101-000000-000000/swiftpm.log"
    let docPath = root + "/docs/result.md"
    FileManager.default.createFile(atPath: docPath, contents: Data(doc.utf8)); files.append(docPath)

    let rel = { (p: String) in String(p.dropFirst(root.count + 1)) }
    let plan = SpaceCleaner.plan(root: root, includeBuild: false)
    out.planned = plan.items.map { rel($0.path) }
    out.evidence = plan.referenced.map(rel)
    out.plannedBuild = SpaceCleaner.plan(root: root, includeBuild: true).items.filter { $0.category == .buildProduct }.map { rel($0.path) }

    // Swap one planned item for a new directory with the same name before applying.
    let swapped = root + "/.runtime/state/app/App-build-20261101-221235-500517.app"
    rmdir(swapped); mkdir(swapped, 0o700)
    var trashed: [String] = []
    let applied = SpaceCleaner.apply(plan) { trashed.append(rel($0.path)) }
    out.trashed = trashed
    out.skipped = applied.skipped.map(rel)
    out.ok = true
    return out
}
