import Darwin
import Foundation
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.

/// Writes discovery-like files into a private temp directory and returns what
/// `RuntimeDiscovery.candidates` keeps. Removes only the files it created.
func discoveryCandidatesFixture() -> [RuntimeDiscovery.Candidate]? {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    let dir = base + "/egw-discovery-\(UUID().uuidString)"
    guard mkdir(dir, 0o700) == 0 else { return nil }
    var created: [String] = []
    defer {
        for path in created { unlink(path) }
        rmdir(dir)
    }
    func put(_ name: String, _ text: String, mode: mode_t = 0o600) -> Bool {
        let path = dir + "/" + name
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return false }
        created.append(path)
        let data = Array(text.utf8)
        let ok = Darwin.write(fd, data, data.count) == data.count
        close(fd)
        return ok
    }
    let ours = "avd.id=\(RuntimeDiscovery.avd)\ngrpc.jwks=/j/ours\ngrpc.jwk_active=/j/ours/active.jwk\n"
    guard put("pid_4242.ini", ours),
          put("pid_5151.ini", "avd.id=other_avd\ngrpc.jwks=/j\ngrpc.jwk_active=/j/a\n"),
          put("pid_6161.ini", "avd.id=\(RuntimeDiscovery.avd)\n"),        // no gRPC fields
          put("pid_x.ini", ours),                                           // not a pid
          put("pid_0077.ini", ours),                                        // not canonical
          put("notes.txt", ours) else { return nil }
    let link = dir + "/pid_7171.ini"
    guard symlink(dir + "/pid_4242.ini", link) == 0 else { return nil }
    created.append(link)
    return RuntimeDiscovery.candidates(in: dir)
}
