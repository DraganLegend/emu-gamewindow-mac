import CoreGraphics
import Darwin
import Foundation
import InputCore
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.

private func tempDir(_ prefix: String) -> String {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    return base + "/\(prefix)-\(UUID().uuidString)"
}

/// Saves two screenshots into a fresh directory; returns (names ok, files private, distinct, png magic).
func screenshotFixture() -> (Bool, Bool, Bool, Bool) {
    let dir = tempDir("egw-shots")
    var made: [String] = []
    defer { for p in made { unlink(p) }; rmdir(dir) }
    guard let image = FrameRenderer.image(rgba: Data(repeating: 200, count: 4 * 4 * 4), width: 4, height: 4) else { return (false, false, false, false) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    guard let a = GameScreenshot.save(image, directory: dir, date: date) else { return (false, false, false, false) }
    made.append(a)
    let b = GameScreenshot.save(image, directory: dir, date: date.addingTimeInterval(0.001))
    if let b { made.append(b) }
    let same = GameScreenshot.save(image, directory: dir, date: date)   // same name must not overwrite
    var info = stat()
    let privateFile = lstat(a, &info) == 0 && info.st_mode & 0o777 == 0o600
    var dirInfo = stat()
    let privateDir = lstat(dir, &dirInfo) == 0 && dirInfo.st_mode & 0o777 == 0o700
    let data = FileManager.default.contents(atPath: a) ?? Data()
    let png = data.starts(with: [137, 80, 78, 71])
    let name = URL(fileURLWithPath: a).lastPathComponent
    return (name.hasPrefix("EGW-") && name.hasSuffix(".png"), privateFile && privateDir, b != nil && same == nil, png)
}

/// Save/list/load named profiles in a fresh directory.
func profileFixture() -> (names: [String], roundTrip: Bool, missingFails: Bool, badNameFails: Bool) {
    let dir = tempDir("egw-keymaps")
    defer {
        for name in ["主線", "boss"] { unlink(dir + "/" + name + ".json") }
        rmdir(dir)
    }
    guard let profile = try? MappingProfile(bindings: [.init(keyCode: 14, label: "E", point: .init(x: 0.3, y: 0.6))]) else {
        return ([], false, false, false)
    }
    let ok1 = (try? GameKeymapStore.saveProfile(profile, name: " 主線 ", directory: dir)) != nil
    let ok2 = (try? GameKeymapStore.saveProfile(try! MappingProfile(bindings: []), name: "boss", directory: dir)) != nil
    let names = GameKeymapStore.profileNames(directory: dir)
    let loaded = try? GameKeymapStore.loadProfile(name: "主線", directory: dir)
    let missing = (try? GameKeymapStore.loadProfile(name: "nope", directory: dir)) == nil
    let bad = (try? GameKeymapStore.saveProfile(profile, name: "../x", directory: dir)) == nil
    return (names, ok1 && ok2 && loaded == profile, missing, bad)
}
