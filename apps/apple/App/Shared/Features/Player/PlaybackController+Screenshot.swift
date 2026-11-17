import CoreGraphics
import DiagnosticsKit
import PlaybackKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PlaybackController {
    /// 截当前帧（视频 + 字幕合成）为 PNG，保存到「图片」，返回文件名（失败给错误文案）。
    ///
    /// 只有取帧留在调用线程（`captureFrameRGBA` 必须持引擎主锁、与渲染线程串行）；
    /// RGBA → PNG 编码（4K 一帧 33MB 的整份拷贝 + CGContext + PNG 压缩，数百 ms）与
    /// 写盘都挪到后台——此前整条链路同步跑在主线程，截图瞬间 HUD / 手势 / 弹幕全冻。
    func captureScreenshot() async -> String? {
        guard let engine, let params = state.videoParams,
              params.width > 0, params.height > 0
        else {
            setupError = "还没有可截的画面"
            return nil
        }
        let width = params.width
        let height = params.height
        let directory = AppStorageDirectories.screenshots
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "截图-\(currentTitle?.prefix(40) ?? "frame")-\(formatter.string(from: Date())).png"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .filter { !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " || $0 == "-" || $0 == ".") }
        let url = directory.appending(path: name)

        let rgba: [UInt8]
        do {
            rgba = try engine.captureFrameRGBA(width: width, height: height)
        } catch {
            setupError = "截图失败：\(error)"
            return nil
        }

        // 编码 + 写盘下主线程：捕获的全是 Sendable 值（缓冲 / 尺寸 / 目录 / 文件名），
        // 不碰 self 的 UI 状态；失败文案带回主线程再落 setupError。
        let now = Date()
        let failure: String? = await Task.detached(priority: .userInitiated) {
            guard let image = Self.pngImage(fromRGBA: rgba, width: width, height: height) else {
                return "截图编码失败"
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.write(to: url)
                return nil
            } catch {
                return "截图失败：\(error)"
            }
        }.value
        PlaybackLog.info(
            "截图编码写盘 \(width)x\(height) 耗时=\(String(format: "%.0f", Date().timeIntervalSince(now) * 1000))ms"
        )

        if let failure {
            setupError = failure
            return nil
        }
        AppDiagnostics.requestStorageMaintenance()
        return name
    }

    /// RGBA8 缓冲 → PNG Data（截图用，双端同一套 CoreGraphics）。
    /// `nonisolated`：纯函数、不碰任何实例状态，截图编码要在后台任务里跑。
    nonisolated static func pngImage(fromRGBA pixels: [UInt8], width: Int, height: Int) -> Data? {
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
