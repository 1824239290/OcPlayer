import Foundation

/// 一次地址探活的结果。
public struct ServerProbeResult: Sendable, Equatable {
    /// 探活的地址（原样返回，方便调用方对号入座）。
    public let url: URL
    /// 一次往返的耗时（秒）。只做**相对比较**用：择优看的是「哪个更快」，
    /// 绝对值受首次 DNS / 连接握手影响，不适合当指标读。
    public let latency: TimeInterval
    /// 服务器 ID（`/System/Info/Public` 的 `Id`）。同一台服务器所有地址都报同一个。
    public let serverID: String?
    public let serverName: String?
    public let productName: String?
    public let version: String?

    public init(url: URL, latency: TimeInterval, serverID: String?,
                serverName: String? = nil, productName: String? = nil, version: String? = nil) {
        self.url = url
        self.latency = latency
        self.serverID = serverID
        self.serverName = serverName
        self.productName = productName
        self.version = version
    }
}

/// 「添加地址」这种需要**用户可读结论**的场景的三态结果。
public enum ServerAddressCheck: Sendable {
    /// 地址可达，且（能校验时）确认是同一台服务器。
    case reachable(ServerProbeResult)
    /// 地址可达，但报的是**另一个**服务器 ID —— 多半是另一台机器 / 别人的服务器，
    /// 不能并进当前档案（并进去等于把会话指向别人家）。
    case differentServer(serverID: String?)
    /// 连不上：超时、拒绝连接、解析不了，或响应不是 Jellyfin / Emby。
    case unreachable
}

/// `/System/Info/Public` 探活。
///
/// 这个端点两家同形、**不需要鉴权**（登录流程 `MediaServerLogin.start` 也用它），
/// 响应里带服务器 `Id` —— 这一点是「多地址合并」的安全底座：地址换了，服务器 ID
/// 必须还是同一个，否则不能把会话切过去。
///
/// `sessionConfiguration` 是测试注入口（塞 `URLProtocol` mock），业务代码不用传。
public struct ServerProbe: Sendable {

    /// 单次探活的超时。刻意短：探活发生在每次决议（启动 / 网络变化 / 请求失败）的
    /// 关键路径上，宁可判「这个地址现在不可用」，也不要让首屏等一个黑洞地址。
    public var timeout: TimeInterval

    public var sessionConfiguration: URLSessionConfiguration

    /// 测试注入：非 nil 时取代真实请求，用于构造确定性延迟 / 失败组合。
    var inject: (@Sendable (URL) async -> ServerProbeResult?)?

    public init(timeout: TimeInterval = 2, sessionConfiguration: URLSessionConfiguration = .default) {
        self.timeout = timeout
        self.sessionConfiguration = sessionConfiguration
    }

    init(
        timeout: TimeInterval = 2,
        sessionConfiguration: URLSessionConfiguration = .default,
        inject: (@Sendable (URL) async -> ServerProbeResult?)? = nil
    ) {
        self.timeout = timeout
        self.sessionConfiguration = sessionConfiguration
        self.inject = inject
    }

    /// 探活一个地址。返回 nil = 不可达 / 不是预期的服务器。
    ///
    /// `expectedServerID` 非空时会校验响应里的 `Id`：**对不上就判失败**。
    /// 校验不到（服务器没报 Id）时放行 —— 宁可用，也不要因为一个字段缺失
    /// 把可用地址全判死。
    public func probe(
        url: URL,
        authorizationHeader: String? = nil,
        expectedServerID: String? = nil
    ) async -> ServerProbeResult? {
        if let inject {
            guard let result = await inject(url) else { return nil }
            if let expectedServerID, let actual = result.serverID, !actual.isEmpty,
               actual != expectedServerID {
                return nil
            }
            return result
        }
        return await request(url: url, authorizationHeader: authorizationHeader,
                             expectedServerID: expectedServerID)
    }

    // MARK: - 真实请求

    private func request(
        url: URL,
        authorizationHeader: String?,
        expectedServerID: String?
    ) async -> ServerProbeResult? {
        let target: URL
        do {
            target = try ServerURL.absolute(base: url, path: "/System/Info/Public")
        } catch {
            return nil
        }

        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // 探活要的是「现在通不通」：等网络恢复是请求层的事，不是这里的事。
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let userAgent = ClientIdentity.customUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .embyFirstLetterLowered
            // ⚠️ 解不出来 = **不是**这台服务器，判不可达。
            //
            // `/System/Info/Public` 的四个字段是两家的公共契约，真正的 Jellyfin /
            // Emby 一定给得出；反代的 SPA fallback（`try_files … /index.html`）、
            // NAS 管理页、任意静态服务器则会回 200 + 一段 HTML。此前用 `try?` 吞掉
            // 解码失败、再靠 `info?.id` 为 nil 跳过 Id 校验，于是这类地址被判「可达」：
            // 它通常比真服务器更快，会被选为当前地址、探活又永远成功（粘性不切走），
            // 而 API 请求全部解不出来 → 卡死在错地址上只能用户手动处理。
            // 登录路径本来就是严格解码（`MediaServerLogin.start`），口径在这里对齐。
            guard let info = try? decoder.decode(EmbyPublicSystemInfoDTO.self, from: data),
                  Self.looksLikeMediaServer(info) else {
                return nil
            }
            if let expectedServerID, let actual = info.id, !actual.isEmpty, actual != expectedServerID {
                return nil
            }
            return ServerProbeResult(
                url: url,
                latency: Date().timeIntervalSince(start),
                serverID: info.id,
                serverName: info.serverName,
                productName: info.productName,
                version: info.version
            )
        } catch {
            return nil
        }
    }

    // MARK: - 给 UI 用的组合口

    /// 响应体像不像一台媒体服务器。`/System/Info/Public` 在两家产品上都会给出
    /// 这四个字段，所以「四个全空」只能说明这不是我们认识的对端（空 JSON 对象、
    /// 只有无关字段的接口、被反代改写的响应）。
    ///
    /// 刻意**不**要求 `Id` 必有：服务器没报 `Id` 时只失去地址校验能力，不该把一条
    /// 本来可用的地址判死（那是 `expectedServerID` 那层的宽容）。
    private static func looksLikeMediaServer(_ info: EmbyPublicSystemInfoDTO) -> Bool {
        func present(_ value: String?) -> Bool { !(value ?? "").isEmpty }
        return present(info.id) || present(info.serverName)
            || present(info.version) || present(info.productName)
    }

    /// 「添加 / 校验一个地址」用的三态结果：可达 but 换了台服务器时必须说清楚，
    /// 不能笼统报「连不上」。
    public static func check(
        url: URL,
        authorizationHeader: String? = nil,
        expectedServerID: String? = nil,
        timeout: TimeInterval = 5,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async -> ServerAddressCheck {
        let probe = ServerProbe(timeout: timeout, sessionConfiguration: sessionConfiguration)
        guard let result = await probe.probe(url: url, authorizationHeader: authorizationHeader) else {
            return .unreachable
        }
        if let expectedServerID, let actual = result.serverID, !actual.isEmpty,
           actual != expectedServerID {
            return .differentServer(serverID: actual)
        }
        return .reachable(result)
    }

    /// 并发探活一组地址，返回**最快**的那个可达结果；都不可达时 nil。
    ///
    /// 「用档案里的哪个地址去重新登录」用它：`baseURL` 可能是在家存的局域网地址，
    /// 人已经出门了，直接拿它去探活必然失败，而 Tailscale 那条是通的。
    public static func firstReachable(
        of urls: [URL],
        authorizationHeader: String? = nil,
        expectedServerID: String? = nil,
        timeout: TimeInterval = 2,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async -> ServerProbeResult? {
        guard !urls.isEmpty else { return nil }
        let probe = ServerProbe(timeout: timeout, sessionConfiguration: sessionConfiguration)
        return await withTaskGroup(of: ServerProbeResult?.self) { group in
            for url in urls {
                group.addTask {
                    await probe.probe(url: url, authorizationHeader: authorizationHeader,
                                      expectedServerID: expectedServerID)
                }
            }
            var best: ServerProbeResult?
            for await result in group {
                guard let result else { continue }
                if best == nil || result.latency < best!.latency { best = result }
            }
            return best
        }
    }
}
