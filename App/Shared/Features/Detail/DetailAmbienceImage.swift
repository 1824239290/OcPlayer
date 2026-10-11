import AppDesignKit
import Foundation

/// 氛围底图预热的唯一实现：800 宽 URL + 512 解码（与 `BackdropAmbienceView` /
/// 整窗层完全同参，保证视图层的 `RemoteImage` 首帧命中缓存）。
///
/// 点击预取（`AppModel+DetailPrefetch`）与进页（`DetailViewModel.prewarmAmbience`）
/// 共用——参数曾两处手写保持一致，漂移就是「首帧不命中」的隐性回退。
enum DetailAmbienceImage {
    /// 底图 URL 的宽度档（视图层 `backdropTarget(width:)` 同参）。
    static let urlWidth = 800
    /// 解码像素档（视图层 `RemoteImage(maxPixelSize:)` 同参）。
    static let decodePixels = 512

    /// 已缓存立即返回 true；否则加载并回报成功与否。调用方不管状态的当预热用。
    @discardableResult
    static func prewarm(url: URL, authHeader: String?) async -> Bool {
        if ImagePipeline.shared.memoryCachedImage(
            url: url, authHeader: authHeader, maxPixelSize: decodePixels) != nil {
            return true
        }
        return (try? await ImagePipeline.shared.load(
            url, authHeader: authHeader, maxPixelSize: decodePixels)) != nil
    }
}
