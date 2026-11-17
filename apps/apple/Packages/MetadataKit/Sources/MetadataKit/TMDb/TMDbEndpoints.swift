import Foundation

/// TMDB 的**端点集合**：API 根 + 图片 CDN 根。
///
/// ## 为什么不是两个 `static let`
///
/// 原先 API 根写死在 `TMDbClient.baseURL`、图片根写死在 `TMDbImageSize.url` 的字符串
/// 里。两个常量都能满足「官方直连」，但一接镜像就散架：设置页改完地址，这两处各自
/// 不知道去哪儿读，只能要求重启；更糟的是「图片已经是镜像域名、请求却仍带服务端
/// 认证头」这类跨模块判断（见 `DisplayMetadata.isTMDbImage`）会因为 host 比的是
/// 写死的 `image.tmdb.org` 而判错。
///
/// 所以把「当前生效的两个根」收成一个值类型：判据、拼 URL、请求都从同一个来源出发。
///
/// ## 镜像约定（设置 → 镜像源）
///
/// - **API 根**：用户填的路径**原样使用**（版本段 `/3` 填不填都行），只填域名时
///   自动补 `/3`（TMDB 的 v3 版本段）。
/// - **图片根**：必须是**尺寸段之前**的路径；只填域名时自动补 `/t/p`。
///   镜像通常由 nginx/CDN 直接反代 `image.tmdb.org/t/p`，所以这两条能把绝大多数
///   `https://image.tmdb.org/...` 形状的地址吃下去。
public struct TMDbEndpoints: Sendable, Equatable {
    public let apiBaseURL: URL
    public let imageBaseURL: URL

    /// 官方直连（未配置镜像 / 总开关关闭时的唯一常量）。
    public static let official = TMDbEndpoints(
        apiBaseURL: URL(string: "https://api.themoviedb.org/3")!,
        imageBaseURL: URL(string: "https://image.tmdb.org/t/p")!)

    public init(apiBaseURL: URL, imageBaseURL: URL) {
        self.apiBaseURL = apiBaseURL
        self.imageBaseURL = imageBaseURL
    }

    /// host 判据统一走这里：`DisplayMetadata.isTMDbImage` 用它决定**不带**服务端认证头。
    /// 小写化后再比（`URL.host` 在某些构造路径上会保留用户输入的大小写）。
    public var apiHost: String? { apiBaseURL.host?.lowercased() }

    public var imageHost: String? { imageBaseURL.host?.lowercased() }

    /// 拼出可直接下载的图片 URL：`<图片根>/<档位><path>`。
    ///
    /// **免鉴权**：TMDB 的图片 CDN 不校验 key，所以调用方传 `authHeader` 时应传 nil
    /// （判据见 `DisplayMetadata.isTMDbImage`）。
    public func imageURL(path: String?, size: TMDbImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let base = imageBaseURL.absoluteString
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmedBase)/\(size.rawValue)\(normalizedPath)")
    }
}

/// 镜像端点的**读取口**：`UserDefaults` 里的原始字符串 → 可用的 `TMDbEndpoints`。
///
/// 与 `TMDbCredentialStore` / `TMDbPreferences` 同款（协议不必加：这里没有需要替身的
/// 外部依赖，纯读键 + 纯解析；用例直接构造带独立 suite 的实例即可）。
///
/// **键的三条约定**（与 App 设置页共享，App 侧有 `MirrorKeyContractTests` 钉住）：
/// 1. 开关 `mirrorEnabledKey` 与 `BangumiKit.BangumiURL.mirrorEnabledKey` **互不相干**
///    ——镜像按线路配，两家镜像常是不同的提供方；
/// 2. 三个键都只由 App 写（「设置 → TMDB 元数据补全 → 镜像源」），包只读；
/// 3. 任何一项为空 / 非法 / 开关关闭 → 该项退回官方，**不**影响另一项
///    （用户可能只镜像 API、图片继续直连）。
public struct TMDbEndpointSettings: @unchecked Sendable {
    /// TMDB 镜像开关（Bool）。
    public static let mirrorEnabledKey = "dev.jumusu.ocplayer.tmdb.mirrorEnabled"
    /// TMDB API 镜像根（String）。空 = 官方。
    public static let apiMirrorKey = "dev.jumusu.ocplayer.tmdb.mirrorAPIBaseURL"
    /// TMDB 图片镜像根（String）。空 = 官方。
    public static let imageMirrorKey = "dev.jumusu.ocplayer.tmdb.mirrorImageBaseURL"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mirrorEnabled: Bool {
        defaults.bool(forKey: Self.mirrorEnabledKey)
    }

    /// 设置页输入框的回显原文（不做规范化：用户看到的就是自己填的）。
    public var apiMirrorRawValue: String? { Self.nonEmpty(defaults.string(forKey: Self.apiMirrorKey)) }
    public var imageMirrorRawValue: String? {
        Self.nonEmpty(defaults.string(forKey: Self.imageMirrorKey))
    }

    /// 当前生效的端点：每一项单独判退化，互不牵连。
    public var endpoints: TMDbEndpoints {
        guard mirrorEnabled else { return .official }
        return TMDbEndpoints(
            apiBaseURL: Self.normalizedAPIBase(apiMirrorRawValue) ?? TMDbEndpoints.official.apiBaseURL,
            imageBaseURL: Self.normalizedImageBase(imageMirrorRawValue) ?? TMDbEndpoints.official.imageBaseURL)
    }

    // MARK: - 解析（纯函数，用例直接驱动）

    /// API 根：`https://host[:port][/path]`，只填域名时补 `/3`。
    ///
    /// 规则细节：路径原样保留（镜像可能挂在 `/tmdb/3` 这种前缀下），只做三件事——
    /// 去尾斜杠、去查询串与片段、把「空路径」补成 `/3`。
    public static func normalizedAPIBase(_ rawValue: String?) -> URL? {
        guard var components = parse(rawValue) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.isEmpty ? "/3" : path
        return components.url
    }

    /// 图片根：必须是**尺寸段之前**的路径，只填域名时补 `/t/p`。
    ///
    /// 顺手吃掉一类常见误填：用户直接粘一张图（`…/t/p/w500/xx.jpg` 或 `…/t/p/w500`）。
    /// 末尾若是已知档位段就丢掉——否则会拼出 `…/t/p/w500/w342/xx.jpg` 这种坏 URL。
    public static func normalizedImageBase(_ rawValue: String?) -> URL? {
        guard var components = parse(rawValue) else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        if let last = segments.last, isImageSizeSegment(last) { segments.removeLast() }
        components.path = segments.isEmpty ? "/t/p" : "/" + segments.joined(separator: "/")
        return components.url
    }

    /// 能否解析成「http(s) + 有 host」。设置页用它给出即时校验提示
    /// （`false` = 这一项会被静默退回官方，用户该看到提示）。
    public static func isParseable(_ rawValue: String?) -> Bool {
        parse(rawValue) != nil
    }

    /// 规范化后的可读形态（设置页「当前生效」预览用）。
    public static func displayString(forAPI rawValue: String?) -> String? {
        normalizedAPIBase(rawValue)?.absoluteString
    }

    public static func displayString(forImage rawValue: String?) -> String? {
        normalizedImageBase(rawValue)?.absoluteString
    }

    // MARK: - 内部

    static func parse(_ rawValue: String?) -> URLComponents? {
        guard let trimmed = nonEmpty(rawValue) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        // 粘贴带查询串的地址（`?api_key=…`）不该被带进每个请求：镜像不应依赖它。
        components.query = nil
        components.fragment = nil
        return components
    }

    static func nonEmpty(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isImageSizeSegment(_ segment: String) -> Bool {
        if segment == TMDbImageSize.original.rawValue { return true }
        return TMDbImageSize.allCases.contains { $0.rawValue == segment }
    }
}
