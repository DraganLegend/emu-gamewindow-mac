import CoreGraphics
import Foundation
import InputCore
@testable import EGWHost

// Foundation/CoreGraphics helpers stay separate from Testing for the installed CLT.

/// Marks one source pixel, turns the picture with FrameRenderer, and checks
/// the marked pixel lands where GameGeometry says the panel point is shown.
/// Returns the number of mismatches (0 = renderer and input math agree).
func rendererGeometryMismatches() -> Int {
    let w = 6, h = 4
    var mismatches = 0
    for turns in 0..<4 {
        for (px, py) in [(0, 0), (5, 0), (1, 3), (4, 2)] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes[(py * w + px) * 4] = 255
            guard let source = FrameRenderer.image(rgba: Data(bytes), width: w, height: h),
                  let turned = FrameRenderer.rotated(source, clockwise: turns),
                  let geometry = GameGeometry(pictureWidth: w, pictureHeight: h, streamRotation: 0,
                                              streamMap: .cw, viewTurns: turns) else { return -1 }
            let ow = turned.width, oh = turned.height
            guard ow == geometry.displayWidth, oh == geometry.displayHeight else { mismatches += 1; continue }
            var out = [UInt8](repeating: 0, count: ow * oh * 4)
            let drawn: Bool = out.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: ow, height: oh, bitsPerComponent: 8,
                                              bytesPerRow: ow * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(turned, in: CGRect(x: 0, y: 0, width: ow, height: oh))
                return true
            }
            guard drawn else { return -1 }
            // Memory row 0 is the top row.
            let found = (0..<(ow * oh)).filter { out[$0 * 4] > 128 }
            let (u, v) = geometry.display(fromPanel: (Double(px) + 0.5) / Double(w), (Double(py) + 0.5) / Double(h))
            let expected = Int(v * Double(oh)) * ow + Int(u * Double(ow))
            if found != [expected] { mismatches += 1 }
            // And the click on that displayed pixel maps back to the source pixel.
            let (bx, by) = geometry.panel(fromDisplay: u, v)
            if Int(bx * Double(w)) != px || Int(by * Double(h)) != py { mismatches += 1 }
        }
    }
    return mismatches
}
