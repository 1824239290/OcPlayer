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
        return URL(string: "https://\(domain)\(normalizedPath)")!
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

/// URL 构建入口。OAuth 域名由 `authDomain` 决定（origin → bgm.tv，next → next.bgm.tv）。
public enum BangumiURL {
    public enum AuthDomain: String, Sendable {
        case origin
        case next
    }

    public static nonisolated var domains: BangumiDomains {
        BangumiDomains(mirrorRootDomain: mirrorRootDomain)
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

    public static nonisolated func auth(path: String = "", authDomain: AuthDomain) -> URL {
        switch authDomain {
        case .origin: return main(path: path)
        case .next: return next(path: path)
        }
    }

    /// 把 lain.bgm.tv 的图床地址重写到当前镜像的图片域名（仅当 host 匹配 CDN 时），并强制使用 HTTPS。
    /// 纯相对路径（无 host）原样返回——强行加 scheme 会拼出「https:/pic/x.jpg」这种坏 URL。
    public static nonisolated func imageURLString(from rawValue: String) -> String {
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

