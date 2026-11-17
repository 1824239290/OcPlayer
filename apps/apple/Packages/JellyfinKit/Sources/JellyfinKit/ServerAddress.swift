import Foundation

/// 一台服务器的**一个**候选网络地址。
///
/// 同一台 Jellyfin / Emby 常常有好几个入口：家里的局域网 IP、Tailscale 的
/// 100.x 地址、反代域名……它们是同一台服务器（`/System/Info/Public` 报同一个
/// `Id`、同一个 token 就能用），差别只在「从哪条路过去更快 / 现在通不通」。
///
/// 此前 `ServerProfile.baseURL` 只存得下一个地址，于是换地址就必须重新走一遍
/// 登录流程，而档案 id（`serverID:userID`）不变 —— 新登录会把旧地址**覆盖**掉。
/// 地址列表 + `ServerEndpointDirectory` 一起把这件事变成「同一台服务器、多个
/// 入口、运行时择优」。
///
/// `kind` 由地址**算出来**而不是存下来：分类规则会随实现演进，存下来就会把
/// 旧分类当事实带着走（比如以后把 `100.115.x` 也认成 Tailscale）。
public struct ServerAddress: Hashable, Sendable, Identifiable, Codable {

    /// 地址所属的网络类别。只用于展示与排障，**不**参与择优——
    /// 择优一律看实测延迟（Tailscale 直连有时比绕一圈的局域网还快）。
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// 局域网 / 本机：私网 IPv4、`.local`、单标签主机名。
        case lan
        /// Tailscale：`100.64.0.0/10`（CGNAT 网段，Tailscale 专用）或 `*.ts.net`。
        case tailscale
        /// 其它：公网 IP、域名、反代。
        case remote

        /// 地址列表里显示的分类名。
        public var displayName: String {
            switch self {
            case .lan: return "局域网"
            case .tailscale: return "Tailscale"
            case .remote: return "远程"
            }
        }
    }

    public let url: URL

    /// 列表 / `ForEach` 用的稳定标识：地址本身就是身份。
    public var id: String { url.absoluteString }

    public var kind: Kind { Self.classify(url) }

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Codable（就是一条地址字符串，落盘可读、能手工改）

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let url = URL(string: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "服务器地址字符串没法解析成 URL：\(raw)")
        }
        self.url = url
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    // MARK: - 分类

    public static func classify(_ url: URL) -> Kind {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return .remote
        }
        if host.hasSuffix(".ts.net") {
            return .tailscale
        }
        if let octets = ipv4Octets(host) {
            let (a, b) = (octets.0, octets.1)
            // 100.64.0.0/10：Tailscale 给节点分的地址（也就落在了运营商级 NAT 段里）。
            if a == 100, (64...127).contains(b) { return .tailscale }
            if a == 10 { return .lan }
            if a == 172, (16...31).contains(b) { return .lan }
            if a == 192, b == 168 { return .lan }
            if a == 169, b == 254 { return .lan }   // link-local
            if a == 127 { return .lan }             // 本机回环
            return .remote
        }
        // IPv6：唯一本地地址 fc00::/7 与链路本地 fe80::/10 都算局域网。
        let lowered = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lowered == "::1" { return .lan }
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return .lan }
        if lowered.hasPrefix("fe8") || lowered.hasPrefix("fe9")
            || lowered.hasPrefix("fea") || lowered.hasPrefix("feb") { return .lan }
        // 主机名：`.local` 是 mDNS，单标签（`nas`）只可能靠局域网内的 DNS / mDNS 解析。
        if host.hasSuffix(".local") { return .lan }
        if !host.contains(".") { return .lan }
        return .remote
    }

    private static func ipv4Octets(_ host: String) -> (Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else { return nil }
            numbers.append(value)
        }
        return (numbers[0], numbers[1])
    }

    // MARK: - 归一化 / 去重

    /// 归一化成**用于比较**的形式：scheme 与 host 小写、去掉默认端口、去掉路径尾斜杠。
    ///
    /// 只用于判等（同一入口别存两遍），**不**用于发请求 —— 发请求一律用档案里
    /// 原样的地址，避免把用户写的路径 / 端口改掉。
    public static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let port = components.port,
           (components.scheme == "http" && port == 80) || (components.scheme == "https" && port == 443) {
            components.port = nil
        }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path == "/" ? "" : path
        components.fragment = nil
        return components.url ?? url
    }

    /// 两个地址是不是同一个入口（归一化后比较）。
    public static func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// 去重成地址列表：排除 `excluding`（通常是 `baseURL`，它单独占第一位）、
    /// 归一化后去重、保持原顺序。
    ///
    /// 排除与去重都用归一化比较：用户手打「http://NAS.local:8096/」和登录时落盘的
    /// 「http://nas.local:8096」是同一个入口，两边都留着会在管理页显示成两条。
    public static func list(
        from urls: [URL],
        excluding excluded: URL? = nil
    ) -> [ServerAddress] {
        var seen: Set<String> = []
        if let excluded { seen.insert(normalized(excluded).absoluteString) }
        var result: [ServerAddress] = []
        for url in urls {
            let key = normalized(url).absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(ServerAddress(url: url))
        }
        return result
    }
}

/// 服务器地址的拼装：把路径拼在 base 的**路径之后**。
///
/// 关键在「之后」：Emby 档案的 baseURL 带 `/emby` 前缀（见 `MediaServerLogin`），
/// 覆盖式赋值会把前缀吃掉，全链路 404。这里与 `EmbySession.url(path:query:)`、
/// `JellyfinServer.streamURL` 原先各自维护的一份实现行为一致，收敛到一处。
enum ServerURL {

    static func absolute(
        base: URL,
        path: String,
        query: [(String, String)] = []
    ) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw JellyfinError(.other("服务器地址拼接失败：\(path)"))
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            // 用数组而不是字典：`includeItemTypes=Movie,Series` 这类同名多值要保序。
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw JellyfinError(.other("服务器地址拼接失败：\(path)"))
        }
        return url
    }
}
