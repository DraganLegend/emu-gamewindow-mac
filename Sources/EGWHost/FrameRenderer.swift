import CoreGraphics
import Foundation

/// RGBA8888 frame bytes -> CGImage. Live frames arrive upright,
/// so `--flip-frames` stays off by default.
enum FrameRenderer {
    static func image(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard (1...4096).contains(width), (1...4096).contains(height),
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        // The Emulator's alpha is not meaningful for display; ignore it.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The picture turned `turns` quarter turns clockwise as seen by the viewer.
    /// Must agree with `GameGeometry.turn`; a pixel-probe test pins that.
    static func rotated(_ image: CGImage, clockwise turns: Int) -> CGImage? {
        let turns = ((turns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        // CG is y-up: a visual clockwise turn is a negative angle.
        switch turns {
        case 1: context.translateBy(x: 0, y: CGFloat(w)); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: CGFloat(w), y: CGFloat(h)); context.rotate(by: .pi)
        default: context.translateBy(x: CGFloat(h), y: 0); context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
