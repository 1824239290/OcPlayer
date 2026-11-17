import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 一张可平铺的单色噪点板，生成一次、当胶片颗粒反复用。确定性，截图可复现。
enum LoginWallNoiseTexture {
    static let size: CGFloat = 128

    /// 跨平台产出：用 `CGImage` 造（两端都有），再包成各自的位图类型。
    static let image: PlatformImage = make(size: Int(size))

    private static func make(size: Int) -> PlatformImage {
        var rng = SeededRandom(seed: 0x4669_6C6D_4772_6169)
        let pixelCount = size * size
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)

        for index in 0..<pixelCount {
            let value = UInt8(min(max(rng.range(0, 255), 0), 255))
            let offset = index * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }

        let imageSize = CGSize(width: size, height: size)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: size * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            return PlatformImage()
        }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: 2, orientation: .up)
        #else
        return NSImage(cgImage: cgImage, size: imageSize)
        #endif
    }
}
