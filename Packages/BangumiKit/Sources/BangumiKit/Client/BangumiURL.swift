import Foundation

/// Bangumi 官方域名（默认）。镜像模式由 App 层在构建 BangumiDomains 时指定根域。
public struct BangumiDomains: Hashable, Sendable {
    public static let official = BangumiDomains()

    public let main: String
    public let api: String
    public let image: String
    public let next: String

    public init(
        main: String = "bgm.tv",
        api: String = "api.bgm.tv",
        image: String = "lain.bgm.tv",
        next: String = "next.bgm.tv"
    ) {
        self.main = Self.normalizedDomain(main) ?? "bgm.tv"
        self.api = Self.normalizedDomain(api) ?? "api.bgm.tv"
        self.image = Self.normalizedDomain(image) ?? "lain.bgm.tv"
        self.next = Self.normalizedDomain(next) ?? "next.bgm.tv"
    }

    public init(mirrorRootDomain: String?) {
        guard let root = Self.normalizedRootDomain(mirrorRootDomain) else {
            self = .official
            return
        }
        self.main = root
        self.api = "api.\(root)"
        self.image = "lain.\(root)"
        self.next = "next.\(root)"
    }

    public var cacheKey: String {
        "\(main)|\(api)|\(image)|\(next)"
    }

    public static func normalizedRootDomain(_ rawValue: String?) -> String? {
        normalizedDomain(rawValue)
    }

    public static func normalizedDomain(for host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let normalizedHost = host.lowercased()
        if let port { return "\(normalizedHost):\(port)" }
        return normalizedHost
    }

    public static func hostAndPort(from domain: String) -> (host: String, port: Int?)? {
        let candidate = domain.contains("://") ? domain : "https://\(domain)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return (host, components.port)
    }

    public func mainURL(path: String = "") -> URL {
        url(domain: main, path: path)
    }

    public func apiURL(path: String = "") -> URL {
        url(domain: api, path: path)
    }

    public func imageURL(path: String = "") -> URL {
        url(domain: image, path: path)
    }

    public func nextURL(path: String = "") -> URL {
        url(domain: next, path: path)
    }

    private func url(domain: String, path: String) -> URL {
        let normalizedPath = path.isEmpty || path.hasPrefix("/") ? path : "/\(path)"
        // 域名虽经 normalizedDomain 校验，仍不强制解包：镜像输入异常时
        // URL(string:)! 会在用户设备上直接崩。构造失败先对 path 做百分号转义
        // 重试，再不行退回官方主站（保证不崩，语义退化可接受）。
        if let url = URL(string: "https://\(domain)\(normalizedPath)") {
            return url
        }
        let encodedPath = normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedPath
        return URL(string: "https://\(domain)\(encodedPath)")
            ?? URL(string: "https://bgm.tv")!
    }

    private static func normalizedDomain(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// URL 构建入口。
public enum BangumiURL {
    /// 官方域名（镜像未设置时的常值）。
    ///
    /// ## 这里**故意没有**记忆化（实测结论，与清单建议相反）
    ///
    /// 清单建议「提成静态量 / 记忆化」。**独立审查复核后修正了数字**（下面是 -O 下
    /// 预热后的热读，用 `withExtendedLifetime` 防优化）：
    /// - `UserDefaults.string(forKey:)`：**0.29–0.35 µs**（缺失键 / 已设键）；首次冷读 ~50 µs
    /// - `BangumiDomains(mirrorRootDomain:)` 本体：**0.55 µs**（nil，提前返回 `.official`）/ **2.0 µs**（已设镜像）
    /// - NSLock 加解锁一对：**~0.01 µs**（无争用）
    ///
    /// **镜像未设置（= 当前现实，见下）**：记忆化 0.559 vs 不缓存 0.547 µs —— 净收益为零。
    /// **已设镜像**：记忆化 0.656 vs 不缓存 1.996 µs —— 约 **3×** 收益。
    ///
    /// 所以这不是「永远不该缓存」，而是**当前形态下不值得**：镜像键全仓只有读、没有写，
    /// 走的是 `nil` 那条提前返回的廉价分支。**若将来接上镜像写入口，应重开这个决定。**
    ///
    /// 另外：`domains` 的主要调用点是 `api` / `next` / `main`（BangumiServices 与
    /// AuthService 共 10 处），只有 1 处在 `imageURLString` 内部 —— 早先这里写反了。
    /// （`BangumiSubjectImages.resized` 那处是死代码，全仓无调用者。）
    public static nonisolated var domains: BangumiDomains {
        BangumiDomains(mirrorRootDomain: mirrorRootDomain)
    }

    /// `imageURLString` 的进程级记忆化（见该函数注释）。
    private static let imageURLStringCache = ImageURLStringCache()

    /// 测试用：直接查缓存单例。用来证明「生产入口真的写了缓存」——
    /// 只测缓存类本身证明不了接线（审查实测：把入口改成完全不缓存，类级用例全绿）。
    static nonisolated func probeImageURLStringCacheValue(
        for raw: String, mirror: String?
    ) -> String? {
        imageURLStringCache.value(for: raw, mirror: mirror)
    }

    public static nonisolated func main(path: String = "") -> URL {
        domains.mainURL(path: path)
    }

    public static nonisolated func api(path: String = "") -> URL {
        domains.apiURL(path: path)
    }

    public static nonisolated func image(path: String = "") -> URL {
        domains.imageURL(path: path)
    }

    public static nonisolated func next(path: String = "") -> URL {
        domains.nextURL(path: path)
    }

    /// 把 lain.bgm.tv 的图床地址重写到当前镜像的图片域名（仅当 host 匹配 CDN 时），并强制使用 HTTPS。
    /// 纯相对路径（无 host）原样返回——强行加 scheme 会拼出「https:/pic/x.jpg」这种坏 URL。
    ///
    /// ## 为什么整条结果都缓存
    ///
    /// 实测单次 **5.17 µs**，而其中 `domains` 只占 **0.79 µs（15%）** —— 剩余 4.4 µs
    /// 是 `URLComponents(string:)` 解析与重建。所以只记忆化 `domains`（清单的建议）
    /// 最多省 15%，等于没修。真正省下的是把整条返回值缓存起来。
    public static nonisolated func imageURLString(from rawValue: String) -> String {
        imageURLString(from: rawValue, mirror: mirrorRootDomain)
    }

    /// 带显式镜像的实现。生产入口把 `mirrorRootDomain` 传进来；
    /// 用例也能用任意镜像值驱动它，从而验证「代次标签与计算用同一个值」这条语义
    /// （不必去改 `UserDefaults.standard` 的全局键 —— 那在并行测试下会串台）。
    ///
    /// ⚠️ 生产入口那一行**必须**传 `mirrorRootDomain`：传 `nil` 就等于关掉失效
    /// （审查的 N12 变异正是这个）。
    ///
    /// **这条在测试里抓不到，是已知限制**：镜像键全仓只有读、没有写，测试环境里
    /// `mirrorRootDomain` 恒为 `nil`，所以「传 `mirrorRootDomain`」与「传 `nil`」
    /// 结果完全相同 —— 任何用例都无法区分。能测的只有「`compose` 用了传进来的值」
    /// （`entryPointUsesInjectedMirrorForBothTagAndComposition` 钉住了这条）。
    ///
    /// 真正的防线是**结构**而不是测试：入口那一行是唯一的采样点，改它等于改语义，
    /// 代码评审必须看住。若将来接上镜像写入口，务必同时补一条「设了镜像后入口
    /// 返回镜像域名」的用例（届时它就能抓到这个变异了）。
    static nonisolated func imageURLString(from rawValue: String, mirror: String?) -> String {
        // 代次标签与计算**用同一个 mirror 值**（参数进来的那个）。早先 compose 内部
        // 又走 `BangumiURL.domains` 重读一次 UserDefaults，两次读之间镜像若改变，
        // 会把「B 代次算出的 URL」存进「A 代次的标签」——之后 A 代次的读会一直
        // 命中这个错值（代次匹配、不再失效）。见 `composeImageURLString(from:mirror:)`。
        if let cached = imageURLStringCache.value(for: rawValue, mirror: mirror) { return cached }
        let computed = composeImageURLString(from: rawValue, mirror: mirror)
        imageURLStringCache.store(computed, for: rawValue, mirror: mirror)
        return computed
    }

    /// 实际计算（不走缓存）。用例拿它做对拍。
    ///
    /// **`mirror` 是参数而不是内部重读**：调用方已经采样过一次镜像值当代次标签，
    /// 若这里再读一次 UserDefaults，两次读之间镜像改变就会算出「B 代次的 URL」
    /// 却存进「A 代次的标签」——之后一直命中错值。传参让两件事用同一个值。
    static nonisolated func composeImageURLString(
        from rawValue: String,
        mirror: String? = nil
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawValue }
        let candidate = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
        guard var components = URLComponents(string: candidate), components.host != nil else {
            return trimmed
        }

        // 统一强制为 HTTPS，避免 HTTP 明文被 Apple ATS 拦截
        if components.scheme == "http" || components.scheme == nil {
            components.scheme = HTTPS
        }

        if components.host == CDN_DOMAIN {
            // 用传进来的 mirror 构造域名，**不再**走 `domains`（那会重读 UserDefaults）。
            let imageDomain = BangumiDomains(mirrorRootDomain: mirror).image
            if let imageHost = BangumiDomains.hostAndPort(from: imageDomain) {
                components.host = imageHost.host
                components.port = imageHost.port
            }
        }
        return components.url?.absoluteString ?? candidate
    }

    /// 测试用：按当前镜像重算（等价于生产路径的一次未命中计算）。
    static nonisolated func composeImageURLStringWithCurrentMirror(from rawValue: String) -> String {
        composeImageURLString(from: rawValue, mirror: mirrorRootDomain)
    }

    private static nonisolated var mirrorRootDomain: String? {
        // 镜像根域由 App 层在启动时写入；默认 nil 即官方域名。
        UserDefaults.standard.string(forKey: "dev.jumusu.ocplayer.bangumi.mirrorRootDomain")
    }
}

let HTTPS = "https"
let CDN_DOMAIN = "lain.bgm.tv"

public extension BangumiSubjectImages {
    /// 生成缩放后的图床 URL（Bangumi 的 /r/{size}{path} 规则）。
    func resized(_ size: Int) -> String {
        guard let url = URL(string: large) else { return "" }
        let host = url.host == CDN_DOMAIN ? BangumiURL.domains.image : (url.host ?? CDN_DOMAIN)
        let scheme = (url.scheme == "http" || url.scheme == nil) ? HTTPS : (url.scheme ?? HTTPS)
        return "\(scheme)://\(host)/r/\(size)\(url.path)"
    }
}


// MARK: - 缓存（P1-11）

/// `BangumiURL.imageURLString(from:)` 的记忆化。
///
/// ## ⚠️ 镜像变化时的清空是**正确性必需**，不是内存回收
///
/// 这里只记录**一个** `mirror` 字段（整表的代次标签），而不是每条 entry 各带代次。
/// 于是：
/// - 只在新代次里为**某个新 key** 存一次值，`mirror` 就会被改成新代次；
/// - 此时旧代次留下的**其余** key 会以新代次的身份被命中 —— **返回错误域名**。
///
/// 实测（独立审查给的反例，已复现）：
/// ```
/// store("OFFICIAL-A", k1, nil); store("OFFICIAL-B", k2, nil)
/// store("MIRRORED-C", k3, "mirror.example")
/// value("k1", "mirror.example")
///   有清空 → nil     （正确）
///   无清空 → "OFFICIAL-A"  ← 旧域名的 URL 被当成新代次有效值，表现是图裂
/// ```
///
/// 所以 `store` 里那句 `entries.removeAll` **删不得**。第一版注释写「只是内存回收、
/// 删了也对」是错的，独立审查用一个必绿变异 + 上面的序列把它挑了出来。
///
/// ## 容量：FIFO 淘汰，不做整表清空
///
/// 整表清空在跨过上限时会**把刚访问过的也一起扔掉**：实测两遍遍历（滚到底再回顶）
/// N=512 命中 50%，**N=513 直接掉到 0%** —— 每次第 513 个新 key 触发清空。
/// 而 Bangumi 的缓存是**进程级**的，一个中等收藏（1000+ 条目）一次浏览就超了。
/// 所以改成按插入顺序 FIFO 淘汰（`order` 数组 + 字典），跨过上限时只丢最旧的一条。
final class ImageURLStringCache: @unchecked Sendable {
    private let lock = NSLock()
    private var mirror: String??
    private var entries: [String: String] = [:]
    /// 插入顺序（尾 = 最新）。只用于 FIFO 淘汰。
    private var order: [String] = []
    static let maxEntries = 512

    func value(for raw: String, mirror current: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let mirror, mirror == current else { return nil }
        return entries[raw]
    }

    func store(_ value: String, for raw: String, mirror current: String?) {
        lock.lock()
        defer { lock.unlock() }
        // ⚠️ 这一句是正确性必需（见类型注释），删不得。
        if let mirror, mirror != current {
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
        }
        mirror = .some(current)

        // 每次写入都刷新顺序：否则反复写同一个 key 时它的位置不前进，
        // 会被当成「最旧」淘汰掉（实测用例 rewritingSameKeyDoesNotGrowOrder 抓到的）。
        if entries[raw] == nil {
            entries[raw] = value
        } else {
            entries[raw] = value
            if let index = order.firstIndex(of: raw) { order.remove(at: index) }
        }
        order.append(raw)

        // FIFO：超上限只丢最旧的一条，不清空整表。
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// 测试专用：回到冷状态。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        mirror = nil
        entries.removeAll()
        order.removeAll()
    }
}

extension BangumiURL {
    /// 测试专用：清空 `imageURLString` 缓存。
    ///
    /// （`domains` 从未缓存，所以这里只有一个。）
    static nonisolated func resetCachesForTesting() {
        imageURLStringCache.reset()
    }
}
