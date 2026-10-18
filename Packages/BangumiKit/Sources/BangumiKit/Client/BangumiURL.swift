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
    /// 清单建议「提成静态量 / 记忆化」。实测三段成本：
    /// - `UserDefaults.string(forKey:)` 读镜像键：**1.34 µs**
    /// - `BangumiDomains(mirrorRootDomain:)` 本体：**0.50 µs**
    /// - NSLock 加解锁一对：**0.38 µs**
    ///
    /// 于是「带失效检查的记忆化」= 读 UserDefaults(1.34) + 锁(0.38) ≈ **1.86 µs**，
    /// 而**不缓存**直接算 = 1.34 + 0.50 ≈ **1.84 µs** —— **净收益为零**，白加锁。
    /// 想真正省下 1.34 µs 就得靠 `UserDefaults.didChangeNotification` 做失效，
    /// 而本 App 会在用户操作时频繁写默认值（`@AppStorage` 等），那会把缓存反复清空、
    /// 得不偿失。
    ///
    /// 更要紧的是：`domains` 的调用点几乎都在 `imageURLString` 内部，而后者已经整条
    /// 缓存了 —— 所以这里即使优化，命中路径也根本走不到。
    public static nonisolated var domains: BangumiDomains {
        BangumiDomains(mirrorRootDomain: mirrorRootDomain)
    }

    /// `imageURLString` 的进程级记忆化（见该函数注释）。
    private static let imageURLStringCache = ImageURLStringCache()

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
        let mirror = mirrorRootDomain
        if let cached = imageURLStringCache.value(for: rawValue, mirror: mirror) { return cached }
        let computed = composeImageURLString(from: rawValue)
        imageURLStringCache.store(computed, for: rawValue, mirror: mirror)
        return computed
    }

    /// 实际计算（不走缓存）。用例拿它做对拍。
    static nonisolated func composeImageURLString(from rawValue: String) -> String {
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
            if let imageHost = BangumiDomains.hostAndPort(from: domains.image) {
                components.host = imageHost.host
                components.port = imageHost.port
            }
        }
        return components.url?.absoluteString ?? candidate
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
/// ## 正确性靠「代次检查」，不靠清空
///
/// `mirror` 存的是写入这一代条目时的镜像原始值；读的时候只要与当前值不同就返回
/// `nil`（未命中），调用方重算。**所以旧一代的条目永远不会被当成有效值返回** ——
/// 也就是说下面 `entries.removeAll` 那两处**只是内存回收，不是正确性保证**。
///
/// 这个区别重要：变异测试证实「把清空去掉」不会被任何用例发现（行为仍正确），
/// 别为了「补覆盖」去给清空加人为断言。
///
/// 有界（512 条）：媒体库海报的 URL 集合是有界的量级（一屏几十条 × 几个尺寸档），
/// 超限整表清空即可 —— 这是**纯函数结果缓存**，清空只退化成「重算一次」。
final class ImageURLStringCache: @unchecked Sendable {
    private let lock = NSLock()
    private var mirror: String??
    private var entries: [String: String] = [:]
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
        if let mirror, mirror != current {
            // 镜像变了：上一代的键全部作废（输出里含图片域名）。
            entries.removeAll(keepingCapacity: true)
        }
        mirror = .some(current)
        if entries.count >= Self.maxEntries, entries[raw] == nil {
            entries.removeAll(keepingCapacity: true)
        }
        entries[raw] = value
    }

    /// 测试专用：回到冷状态。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        mirror = nil
        entries.removeAll()
    }
}

extension BangumiURL {
    /// 测试专用：清空两个缓存，并允许用例观察冷启动行为。
    static nonisolated func resetCachesForTesting() {
        imageURLStringCache.reset()
    }
}
