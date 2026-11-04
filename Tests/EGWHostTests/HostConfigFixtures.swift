import Darwin
import Foundation
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.

/// Loads `egw.config.json` written with `text`/`mode` into a private temp
/// project. Removes only the file and directory it created.
func hostConfigFixture(_ text: String?, mode: mode_t = 0o600) -> HostConfig.Loaded? {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    let dir = base + "/egw-config-\(UUID().uuidString)"
    guard mkdir(dir, 0o700) == 0 else { return nil }
    let path = dir + "/" + HostConfig.fileName
    var created = false
    defer {
        if created { unlink(path) }
        rmdir(dir)
    }
    if let text {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        created = true
        let data = Array(text.utf8)
        let ok = Darwin.write(fd, data, data.count) == data.count
        close(fd)
        guard ok, chmod(path, mode) == 0 else { return nil }
    }
    return HostConfig.load(project: dir)
}
