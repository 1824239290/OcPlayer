import CoreGraphics
import DiagnosticsKit
import ErikaKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PlaybackController {
    /// 截当前帧（视频 + 字幕合成）为 PNG，保存到「图片」，返回文件名（失败给错误文案）。
    func captureScreenshot() -> String? {
        guard let engine, let params = state.videoParams,
              params.width > 0, params.height > 0
        else {
            setupError = "还没有可截的画面"
            return nil
        }
        do {
            let rgba = try engine.captureFrameRGBA(width: params.width, height: params.height)
            guard let image = Self.pngImage(fromRGBA: rgba, width: params.width, height: params.height) else {
                setupError = "截图编码失败"
                return nil
            }
            let directory = AppStorageDirectories.screenshots
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "截图-\(currentTitle?.prefix(40) ?? "frame")-\(formatter.string(from: Date())).png"
                .replacingOccurrences(of: "/", with: "-")
            let url = directory.appending(path: name)
            try image.write(to: url)
            AppDiagnostics.requestStorageMaintenance()
            return name
        } catch {
            setupError = "截图失败：\(error)"
            return nil
        }
    }

    /// RGBA8 缓冲 → PNG Data（截图用，双端同一套 CoreGraphics）。
    static func pngImage(fromRGBA pixels: [UInt8], width: Int, height: Int) -> Data? {
        var data = pixels
        let space = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { pointer -> Data? in
            guard let base = pointer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage()
            else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, "public.png" as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }

}
