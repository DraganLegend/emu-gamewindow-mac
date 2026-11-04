import Darwin
import Foundation
import Metal
@testable import EGWHost

// Foundation/Metal helpers stay separate from Testing for the installed CLT.

private func tempPath(_ name: String) -> String {
    URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/\(name)-\(UUID().uuidString)"
}

/// Mapping lifecycle: private, sized, readable, removed exactly once.
func frameMappingFixture() -> (sized: Bool, privateFile: Bool, copied: Bool, removed: Bool, refusesExisting: Bool) {
    let path = tempPath("egw-frames")
    guard let length = FrameMapping.regionBytes(width: 4, height: 2),
          let mapping = try? FrameMapping(path: path, length: length) else { return (false, false, false, false, false) }
    var info = stat()
    let sized = lstat(path, &info) == 0 && Int(info.st_size) == length && length % FrameMapping.pageSize == 0
    let privateFile = info.st_mode & 0o777 == 0o600
    mapping.pointer.storeBytes(of: UInt8(77), toByteOffset: 5, as: UInt8.self)
    let copied = mapping.copyFrame(width: 4, height: 2)?[5] == 77 && mapping.copyFrame(width: 4096, height: 4096) == nil
    let refusesExisting = (try? FrameMapping(path: path, length: length)) == nil
    mapping.remove(); mapping.remove()
    let removed = lstat(path, &info) != 0
    return (sized, privateFile, copied, removed, refusesExisting)
}

/// Renders a marked source pixel through Metal for every view turn (and one
/// flipped case) and checks it lands where GameGeometry places it.
/// Returns (mismatches, mode) or nil when no Metal device / setup failed.
func metalRendererMismatches() -> (Int, String)? {
    let w = 6, h = 4
    let path = tempPath("frames-metal")
    guard let length = FrameMapping.regionBytes(width: w, height: h),
          let mapping = try? FrameMapping(path: path, length: length),
          let renderer = MetalFrameRenderer(pointer: mapping.pointer, length: mapping.length)?.useNearestSampling() else {
        return nil
    }
    defer { mapping.remove() }
    var mismatches = 0
    let cases: [(turns: Int, flip: Bool)] = [(0, false), (1, false), (2, false), (3, false), (0, true)]
    for (turns, flip) in cases {
        for (px, py) in [(0, 0), (5, 0), (1, 3), (4, 2)] {
            memset(mapping.pointer, 0, w * h * 4)
            mapping.pointer.storeBytes(of: UInt8(255), toByteOffset: (py * w + px) * 4, as: UInt8.self)     // R
            mapping.pointer.storeBytes(of: UInt8(255), toByteOffset: (py * w + px) * 4 + 3, as: UInt8.self) // A
            guard let geometry = GameGeometry(pictureWidth: w, pictureHeight: h, streamRotation: 0, streamMap: .cw, viewTurns: turns) else { return nil }
            let ow = geometry.displayWidth, oh = geometry.displayHeight
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ow, height: oh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            guard let target = renderer.device.makeTexture(descriptor: d),
                  let commands = renderer.render(width: w, height: h, turns: turns, flip: flip, into: target) else { return nil }
            commands.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: ow * oh * 4)
            target.getBytes(&out, bytesPerRow: ow * 4, from: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0)
            let found = (0..<(ow * oh)).filter { out[$0 * 4 + 2] > 128 }   // red channel in BGRA
            let sourceY = flip ? h - 1 - py : py                             // flip mirrors the picture vertically
            let (u, v) = geometry.display(fromPanel: (Double(px) + 0.5) / Double(w), (Double(sourceY) + 0.5) / Double(h))
            if found != [Int(v * Double(oh)) * ow + Int(u * Double(ow))] { mismatches += 1 }
        }
    }
    return (mismatches, renderer.mode.rawValue)
}

/// prepareFastPath against a temporary AVD config: success, and the documented fallbacks.
func prepareFastPathFixture() -> (ok: Bool, unknownDisplay: String?, existingFile: String?) {
    let config = tempPath("avd-config")
    let mapPath = tempPath("frames-prepare")
    FileManager.default.createFile(atPath: config, contents: Data("hw.lcd.width=1280\nhw.lcd.height=720\n".utf8))
    defer { unlink(config) }
    let fast = GameViewSession.prepareFastPath(path: mapPath, avdConfig: config)
    let ok = fast.mapping?.length == 1280 * 1280 * 4 && fast.renderer != nil && fast.fallback == nil
    // While that mapping exists, a second one at the same path is refused.
    let second = GameViewSession.prepareFastPath(path: mapPath, avdConfig: config)
    fast.mapping?.remove()
    let unknown = GameViewSession.prepareFastPath(path: mapPath, avdConfig: config + "-missing")
    return (ok, unknown.fallback, second.fallback)
}
