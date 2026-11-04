import CoreGraphics
import Darwin
import Foundation
import InputCore
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.
func frameRendererChecks() -> Bool {
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
    guard let image = FrameRenderer.image(rgba: pixels, width: 2, height: 1) else { return false }
    return image.width == 2 && image.height == 1
        && FrameRenderer.image(rgba: pixels, width: 2, height: 2) == nil
        && FrameRenderer.image(rgba: Data(), width: 0, height: 0) == nil
        && FrameRenderer.image(rgba: Data(count: 4), width: 5000, height: 1) == nil
}

/// Save/load round trip through a private file in the resolved temp directory.
func keymapStoreChecks() -> Bool {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    let path = base + "/egw-keymap-test-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard (try? GameKeymapStore.load(path: path))?.bindings.isEmpty == true else { return false }
    guard let profile = try? MappingProfile(bindings: [.init(keyCode: 6, label: "Z", point: .init(x: 0.25, y: 0.75))]),
          (try? GameKeymapStore.save(profile, path: path)) != nil,
          let loaded = try? GameKeymapStore.load(path: path), loaded == profile else { return false }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & 0o777 == 0o600 else { return false }
    // A second save replaces atomically and leaves no temporary file behind.
    guard let two = try? MappingProfile(bindings: []), (try? GameKeymapStore.save(two, path: path)) != nil,
          (try? GameKeymapStore.load(path: path))?.bindings.isEmpty == true else { return false }
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { $0.contains(URL(fileURLWithPath: path).lastPathComponent + ".tmp-") }
    // A world-readable file must be refused.
    chmod(path, 0o644)
    return leftovers.isEmpty && (try? GameKeymapStore.load(path: path)) == nil
}
