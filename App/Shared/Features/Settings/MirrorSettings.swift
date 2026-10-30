import AppDesignKit
import BangumiKit
import Foundation
import MetadataKit
import SwiftUI

/// 镜像源在 App 侧的**唯一事实源**：预设值、地址校验、生效值与值预览。
///
/// ## 这是薄壳，不是第二份状态
///
/// 真正的接线在域包里：`BangumiURL.domains` 读「Bangumi 开关 + 根域」，
/// `TMDbEndpointSettings.endpoints` 读「TMDB 开关 + 两个地址」。App 只负责**写键**，
/// 于是不存在「设置页说启用了、请求却还走官方」这种不同步——也正因如此，
/// 两家各自的镜像区块都没有「保存 / 应用 / 重启」按钮：**改完下一个请求就生效**。
///
/// ## 为什么分成两半（2026-10-30 用户口径）
///
/// 镜像最初是设置 hub 里一个独立的「镜像源」子页（一个总开关带三行地址）。
/// 用户的口径是「设置里的位置放到他们自己的栏位里面，比如 bangumi 的镜像源设置
/// 放到 bangumi 栏位里，tmdb 的同理」——因为镜像不是一类**功能**，而是这两家
/// 各自的一条线路：找 Bangumi 的连接设置时，人只会去 Bangumi 页找。
/// 于是开关也一并拆成两个键（`bangumi.mirrorEnabled` / `tmdb.mirrorEnabled`）：
/// 两家镜像通常是两个不同的提供方，共用一个开关只是巧合。
///
/// ## 镜像不是内置服务清单
///
/// 我们不探测、不内置可用镜像的「真相表」：镜像的可用性随网络与时间变化
/// （用户给的截图里那批域名就是半天之内几种不同的污染状态），写死任何一个都会
/// 在它失效之后变成误导。UI 只给**可编辑的地址 + 一个示例**，最终由用户决定。
enum MirrorSettings {

    /// 示例值（UI 里的「填入示例」按钮）。
    ///
    /// - `bangumi.lat`：用户实测国内解析干净、`api.` / `lain.` 子域可用。
    /// - `api.tmdb.org` / `image.tmdb.org`：TMDB 官方备用域（同样的 API 与密钥语义，
    ///   国内可达性比 `api.themoviedb.org` 好）。
    ///
    /// 它们只是**输入辅助**，不是默认值、也不会被自动启用。
    static let bangumiPresetRootDomain = "bangumi.lat"
    static let tmdbPresetAPIBase = "https://api.tmdb.org/3"
    static let tmdbPresetImageBase = "https://image.tmdb.org/t/p"

    // MARK: - Bangumi：生效值

    /// Bangumi 当前生效的四个域名。开关关闭 / 地址非法 → 官方。
    static func bangumiDomains(enabled: Bool, rawValue: String) -> BangumiDomains {
        BangumiDomains(mirrorRootDomain: enabled ? rawValue : nil)
    }

    /// 非空但解析不出主机名 → 一句人话；空 / 合法 → nil。
    ///
    /// **允许留空**：留空表示「回到官方」，是合法状态而不是错误。
    static func bangumiProblem(_ rawValue: String) -> String? {
        guard !trimmed(rawValue).isEmpty else { return nil }
        return BangumiDomains.normalizedRootDomain(rawValue) == nil
            ? "解析不出主机名，Bangumi 仍会走官方域名。"
            : nil
    }

    /// 镜像**是否真的在生效**（开关开 **且** 地址能解析）。
    ///
    /// 与「开关是否打开」是两件事：地址留空 / 填错时域包会静默退回官方，此时仍然
    /// 往 hub 上挂「（镜像）」就是在撒谎——而这个标记存在的全部理由恰恰是
    /// 「别让用户以为线路已经改了」。所以判定必须走这条，不看裸开关。
    static func bangumiMirrorActive(enabled: Bool, rawValue: String) -> Bool {
        enabled && BangumiDomains.normalizedRootDomain(rawValue) != nil
    }

    /// TMDB 同理：两项里**至少一项**能解析就算在生效（另一项独立退回官方）。
    static func tmdbMirrorActive(enabled: Bool, apiRawValue: String, imageRawValue: String) -> Bool {
        guard enabled else { return false }
        return TMDbEndpointSettings.normalizedAPIBase(apiRawValue) != nil
            || TMDbEndpointSettings.normalizedImageBase(imageRawValue) != nil
    }

    /// Bangumi 一行摘要（设置 hub 的值预览 / 段落注解共用）。
    ///
    /// 三种状态要分得开：`nil` = 开关没开（官方直连）；`"已启用（未填地址）"` = 开了
    /// 但没填（等于官方，用户该补地址）；否则是「镜像：<根域>」。
    static func bangumiSummary(enabled: Bool, rawValue: String) -> String? {
        guard enabled else { return nil }
        guard BangumiDomains.normalizedRootDomain(rawValue) != nil else { return "已启用（未填地址）" }
        return "镜像：\(trimmed(rawValue))"
    }

    // MARK: - TMDB：生效值

    /// TMDB 当前生效的端点。开关关闭 / 单项非法 → 该项退回官方。
    static func tmdbEndpoints(enabled: Bool, apiRawValue: String, imageRawValue: String) -> TMDbEndpoints {
        guard enabled else { return .official }
        return TMDbEndpoints(
            apiBaseURL: TMDbEndpointSettings.normalizedAPIBase(apiRawValue)
                ?? TMDbEndpoints.official.apiBaseURL,
            imageBaseURL: TMDbEndpointSettings.normalizedImageBase(imageRawValue)
                ?? TMDbEndpoints.official.imageBaseURL)
    }

    static func tmdbAPIProblem(_ rawValue: String) -> String? {
        guard !trimmed(rawValue).isEmpty else { return nil }
        return TMDbEndpointSettings.normalizedAPIBase(rawValue) == nil
            ? "解析不出主机名，TMDB API 仍会走官方地址。"
            : nil
    }

    static func tmdbImageProblem(_ rawValue: String) -> String? {
        guard !trimmed(rawValue).isEmpty else { return nil }
        return TMDbEndpointSettings.normalizedImageBase(rawValue) == nil
            ? "解析不出主机名，TMDB 图片仍会走官方地址。"
            : nil
    }

    /// TMDB 一行摘要。语义与 `bangumiSummary` 同构。
    static func tmdbSummary(enabled: Bool, apiRawValue: String, imageRawValue: String) -> String? {
        guard enabled else { return nil }
        var parts: [String] = []
        if TMDbEndpointSettings.normalizedAPIBase(apiRawValue) != nil { parts.append("API") }
        if TMDbEndpointSettings.normalizedImageBase(imageRawValue) != nil { parts.append("图片") }
        return parts.isEmpty ? "已启用（未填地址）" : "镜像：" + parts.joined(separator: " + ")
    }

    // MARK: - 复位

    /// 「恢复官方直连」：**连开关一起清**。
    ///
    /// 两家各一个入口（各自页内）。刻意连地址一起清：留着旧地址却把开关关掉，
    /// 下次打开开关时会莫名连到一个早已失效的旧镜像上——那正是这个按钮要消除的状态。
    static func resetBangumi(defaults: UserDefaults = .standard) {
        for key in [SettingsKeys.bangumiMirrorEnabled, SettingsKeys.bangumiMirrorRootDomain] {
            defaults.removeObject(forKey: key)
        }
    }

    static func resetTMDb(defaults: UserDefaults = .standard) {
        for key in [SettingsKeys.tmdbMirrorEnabled,
                    SettingsKeys.tmdbMirrorAPIBaseURL,
                    SettingsKeys.tmdbMirrorImageBaseURL] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func trimmed(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 共用行件

/// 地址解析失败时的非阻断提示（两个镜像段共用）。
///
/// 为什么是「提示」而不是「拦住保存」：镜像地址是用户从别处抄来的，格式不统一
/// （带不带 scheme、带不带路径都可能）；拦在输入框上会让用户卡在一个填错的框里出不去，
/// 而**静默退回官方**才是可用的降级。橙色小字把这件事说清楚即可。
struct MirrorProblemLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .settingsCardCompact()
    }
}
