import CoreModel
import DiagnosticsKit
import Foundation
import Get
import JellyfinAPI

/// 网络层诊断日志（JSONL 落盘 + OSLog 镜像，见 DiagnosticsKit）。
///
/// 只记请求**路径**不记 query（userId / 图片 tag 这类不敏感，但路径足够定位问题）；
/// 任何 token 都由红actor 兜底，绝不进日志。
enum NetworkLog {
    static let logger = DiagnosticLogger(subsystem: "dev.jumusu.OcPlayer", category: "Jellyfin")

    static func requestStarted(_ path: String) {
        logger.debug("请求开始 path=\(path)")
    }

    static func requestSucceeded(_ path: String, duration: TimeInterval) {
        logger.debug("请求成功 path=\(path) duration_ms=\(Int(duration * 1000))")
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        logger.error("请求失败 path=\(path) error=\(error) duration_ms=\(Int(duration * 1000))")
    }

    /// 进度上报这类「尽力而为」的失败：不打断播放，但值得留一条 warning。
    static func reportFailed(_ what: String, error: Error) {
        logger.warning("上报失败 what=\(what) error=\(error)")
    }

    /// `Request.url` 形如 `/Items?userId=…`，只取 path 部分入日志。
    static func logPath(for url: URL?) -> String {
        guard let url else { return "?" }
        return url.path.isEmpty ? url.absoluteString : url.path
    }
}

/// 条目图片类型（对 Jellyfin `ImageType` 的收口，避免 JellyfinAPI 类型漏出包外）。
public enum ItemImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
}

/// 一台已登录（或正要登录）的 Jellyfin 服务器。
///
/// 无状态薄封装：真正的 HTTP 全部走 `JellyfinAPI` 的 `JellyfinClient`，
/// 这里只做「选端点 + 配参数 + DTO → 域模型」。token 由 SDK 自动注入
/// `Authorization` 请求头 —— 不进 URL、不进日志。
public struct JellyfinServer: Sendable {
    public let profile: ServerProfile
    public let client: JellyfinClient

    public var accessToken: String? { client.accessToken }

    init(profile: ServerProfile, client: JellyfinClient) {
        self.profile = profile
        self.client = client
    }

    /// 用已保存的档案 + 本地 token 恢复会话。
    public init?(restoringFrom store: ServerStore) {
        guard let profile = store.currentProfile,
              let token = store.token(for: profile)
        else { return nil }
        self.init(
            profile: profile,
            client: Self.makeClient(baseURL: profile.baseURL, token: token)
        )
    }

    static func makeClient(baseURL: URL, token: String?,
                           sessionConfiguration: URLSessionConfiguration = .default) -> JellyfinClient {
        JellyfinClient(
            configuration: .init(
                url: baseURL,
                accessToken: token,
                client: ClientIdentity.clientName,
                deviceName: ClientIdentity.deviceName,
                deviceID: ClientIdentity.deviceID,
                version: ClientIdentity.version
            ),
            sessionConfiguration: sessionConfiguration
        )
    }

    // MARK: - 登录

    /// 校验地址并创建登录会话。`urlString` 允许「192.168.1.10:8096」这种不带 scheme 的写法。
    /// `sessionConfiguration` 是测试注入口（塞 URLProtocol mock），业务代码不用传。
    public static func startLogin(
        urlString rawURL: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> LoginSession {
        let url = try normalizeServerURL(rawURL)

        // 先用匿名客户端探一下：不是 Jellyfin / 连不上都在这一步报错
        let probeClient = makeClient(baseURL: url, token: nil, sessionConfiguration: sessionConfiguration)
        let info: PublicSystemInfo
        do {
            info = try await probeClient.send(Paths.getPublicSystemInfo).value
        } catch {
            throw JellyfinError.wrap(error)
        }
        return LoginSession(baseURL: url, info: info, client: probeClient)
    }

    /// 「host:port」→「http://host:port/」；已有 scheme 的原样保留（去尾斜杠）。
    public static func normalizeServerURL(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinError(.badServerURL) }
        if text.range(of: "://") == nil {
            // 局域网默认 http；用户写 https:// 的保留
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host(percentEncoded: false), !host.isEmpty,
              url.scheme == "http" || url.scheme == "https"
        else { throw JellyfinError(.badServerURL) }
        return url
    }

    // MARK: - 浏览

    /// 用户的媒体库列表（电影 / 剧集 / 音乐…）。
    public func userViews() async throws -> [MediaLibrary] {
        let result = try await send(Paths.getUserViews(parameters: .init(userID: profile.userID)))
        return (result.items ?? [])
            .map { MediaLibrary(id: $0.id ?? UUID().uuidString, name: $0.name ?? "", collectionType: .init($0.collectionType?.rawValue)) }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }

    /// 首页「最近添加」。
    public func latestItems(limit: Int = 24) async throws -> [MediaItem] {
        try await send(
            Paths.getLatestMedia(parameters: .init(
                userID: profile.userID,
                includeItemTypes: [.movie, .series],
                enableImageTypes: [.primary, .backdrop],
                limit: limit
            ))
        )
        .map(\.domainItem)
    }

    /// 用户收藏的电影 / 剧集（M4 独立收藏页预留）。
    /// Jellyfin 的用户数据只有 `IsFavorite`，不记录收藏发生时间；`DateCreated`
    /// 是媒体条目的入库 / 创建时间，不能对外表述为“最近收藏”。
    /// 返回单页（不递归展开）；收藏为空时调用方负责空态。
    public func favoriteItems(limit: Int = 24) async throws -> [MediaItem] {
        try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                limit: limit,
                sortOrder: [.descending],
                includeItemTypes: [.movie, .series],
                filters: [.isFavorite],
                sortBy: [.dateCreated],
                enableImageTypes: [.primary, .backdrop]
            ))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 首页「继续观看」。
    public func resumeItems() async throws -> [MediaItem] {
        try await send(
            Paths.getResumeItems(parameters: .init(
                userID: profile.userID,
                limit: 24,
                mediaTypes: [.video]
            ))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 「接下来看」：追剧下一集。
    public func nextUp() async throws -> [MediaItem] {
        try await send(
            Paths.getNextUp(parameters: .init(userID: profile.userID, limit: 24))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 条目详情（含演员表 / 简介 / 流派）。
    /// 显式带 `fields`：部分服务器版本默认不返回 People 等扩展字段（SDK 自带的
    /// `Paths.getItem` 不带 fields），显式请求两边都稳。
    public func item(_ id: String) async throws -> MediaItem {
        let request = Request<BaseItemDto>(
            path: "/Items/\(id)",
            query: [
                ("userId", profile.userID),
                ("fields", "People,Genres,Overview"),
            ]
        )
        return try await send(request).domainItem
    }

    /// 媒体库网格浏览。`recursive` = true 时直接铺到叶子（电影库 → 所有电影）。
    public func items(
        parentID: String?,
        kinds: [MediaItem.Kind]? = nil,
        recursive: Bool = true,
        limit: Int = 200
    ) async throws -> [MediaItem] {
        let pageSize = max(limit, 1)
        var startIndex = 0
        var loaded: [MediaItem] = []

        while true {
            let result = try await send(
                Paths.getItems(parameters: .init(
                    userID: profile.userID,
                    startIndex: startIndex,
                    limit: pageSize,
                    isRecursive: recursive,
                    parentID: parentID,
                    includeItemTypes: kinds.map { kinds in
                        kinds.compactMap { kind in BaseItemKind(kind) }
                    },
                    sortBy: [.sortName],
                    enableImageTypes: [.primary, .backdrop],
                    enableTotalRecordCount: true
                ))
            )
            let page = result.items?.map(\.domainItem) ?? []
            loaded.append(contentsOf: page)

            if page.isEmpty
                || result.totalRecordCount.map({ loaded.count >= $0 }) == true
                || (result.totalRecordCount == nil && page.count < pageSize) {
                return loaded
            }
            startIndex += page.count
        }
    }

    /// 剧集 → 季列表。
    public func seasons(seriesID: String) async throws -> [MediaItem] {
        try await send(
            Paths.getSeasons(seriesID: seriesID, parameters: .init(userID: profile.userID))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 剧集 → 集列表（`seasonID` 为 nil 时返回全部）。
    public func episodes(seriesID: String, seasonID: String? = nil) async throws -> [MediaItem] {
        let episodes = try await send(
            Paths.getEpisodes(seriesID: seriesID, parameters: .init(
                userID: profile.userID,
                seasonID: seasonID,
                enableImages: true,
                enableImageTypes: [.primary, .thumb],
                enableUserData: true,
                sortBy: .indexNumber
            ))
        )
        .items?.map(\.domainItem) ?? []
        return episodes.sorted {
            let lhs = ($0.seasonNumber ?? Int.max, $0.episodeNumber ?? Int.max, $0.id)
            let rhs = ($1.seasonNumber ?? Int.max, $1.episodeNumber ?? Int.max, $1.id)
            return lhs < rhs
        }
    }

    /// 「类似推荐」。
    public func similar(itemID: String, limit: Int = 12) async throws -> [MediaItem] {
        try await send(
            Paths.getSimilarItems(itemID: itemID, parameters: .init(userID: profile.userID, limit: limit))
        )
        .items?.map(\.domainItem) ?? []
    }

    // MARK: - URL

    /// 条目图片地址。**不含 token**（加载方带 `Authorization` 头）；`tag` 进 query，
    /// 图片更新时 URL 跟着变，磁盘缓存自然失效。
    public func imageURL(itemID: String, type: ItemImageType = .primary,
                         maxWidth: Int? = nil, tag: String? = nil) throws -> URL {
        let request = Paths.getItemImage(
            itemID: itemID,
            imageType: type.rawValue,
            parameters: .init(maxWidth: maxWidth, tag: tag)
        )
        guard let url = client.url(with: request) else {
            throw JellyfinError(.other("图片地址拼接失败"))
        }
        return url
    }

    /// 直连播放地址（`/Videos/{id}/stream?Static=true`）。认证走请求头交给内核，
    /// 所以 URL 里只有条目 id，没有 token。多 MediaSource 条目可显式带 `mediaSourceId`。
    public func streamURL(
        itemID: String,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil
    ) throws -> String {
        var path = "/Videos/\(itemID)/stream?Static=true"
        if let mediaSourceID {
            let encoded = mediaSourceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? mediaSourceID
            path += "&mediaSourceId=\(encoded)"
        }
        if let playSessionID {
            let encoded = playSessionID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playSessionID
            path += "&playSessionId=\(encoded)"
        }
        guard let url = client.url(path: path) else {
            throw JellyfinError(.other("播放地址拼接失败"))
        }
        return url.absoluteString
    }

    /// 给内核（`open_with_headers`）和图片加载共用的认证头。
    public var authorizationHeader: String {
        ClientIdentity.mediaBrowserAuthorizationHeader(token: accessToken)
    }

    // MARK: - 出错统一包装

    /// 包内共享的请求发送口（ExternalSubtitles 等扩展文件也用它）。
    func send<T: Decodable & Sendable>(_ request: Request<T>) async throws -> T {
        let path = NetworkLog.logPath(for: request.url)
        let start = Date()
        do {
            let value = try await client.send(request).value
            NetworkLog.requestSucceeded(path, duration: Date().timeIntervalSince(start))
            return value
        } catch {
            NetworkLog.requestFailed(path, error: error, duration: Date().timeIntervalSince(start))
            throw JellyfinError.wrap(error)
        }
    }
}

// MARK: - 登录会话

/// 登录成功的产出（对 `AuthenticationResult` 的收口：App 层不 import JellyfinAPI）。
public struct LoginResult: Sendable {
    public let token: String
    public let userID: String
    public let userName: String?

    init(_ result: AuthenticationResult) throws {
        guard let token = result.accessToken, let userID = result.user?.id else {
            throw JellyfinError(.unauthorized)
        }
        self.token = token
        self.userID = userID
        self.userName = result.user?.name
    }
}

/// `startLogin` 之后、拿到 token 之前的中间态：
/// 持有指向该服务器的匿名客户端，Quick Connect 和账号密码都从它走。
public final class LoginSession: Sendable {
    public let baseURL: URL
    public let serverName: String
    public let serverVersion: String?
    let serverID: String?
    let client: JellyfinClient

    init(baseURL: URL, info: PublicSystemInfo, client: JellyfinClient) {
        self.baseURL = baseURL
        self.serverName = info.serverName ?? "Jellyfin"
        self.serverVersion = info.version
        self.serverID = info.id
        self.client = client
    }

    /// Quick Connect 事件流（内置轮询，取消流即取消轮询）。
    public var quickConnectEvents: AsyncThrowingStream<QuickConnect.Event, Error> {
        client.quickConnect.connect(poll: 3, max: 60)
    }

    /// 账号密码登录；Quick Connect 则消费 `quickConnectEvents` 的
    /// `.authenticated(secret:)` 后调 `signIn(quickConnectSecret:)`。两者殊途同归到 `finish`。
    public func signIn(username: String, password: String) async throws -> LoginResult {
        do {
            return try LoginResult(await client.signIn(username: username, password: password))
        } catch let error as JellyfinError {
            throw error
        } catch {
            throw JellyfinError.wrap(error)
        }
    }

    public func signIn(quickConnectSecret: String) async throws -> LoginResult {
        do {
            return try LoginResult(await client.signIn(quickConnectSecret: quickConnectSecret))
        } catch let error as JellyfinError {
            throw error
        } catch {
            throw JellyfinError.wrap(error)
        }
    }

    /// 登录成功 → 落档案 + token，返回可用的服务器会话。
    public func finish(_ result: LoginResult, store: ServerStore) throws -> JellyfinServer {
        let resolvedServerID = serverID ?? baseURL.host(percentEncoded: false) ?? baseURL.absoluteString
        let profile = ServerProfile(
            id: "\(resolvedServerID):\(result.userID)",
            serverName: serverName,
            baseURL: baseURL,
            userID: result.userID,
            userName: result.userName,
            serverVersion: serverVersion
        )
        store.activate(profile, token: result.token)
        return JellyfinServer(profile: profile, client: Self.makeAuthedClient(baseURL: baseURL, token: result.token))
    }

    private static func makeAuthedClient(baseURL: URL, token: String) -> JellyfinClient {
        JellyfinServer.makeClient(baseURL: baseURL, token: token)
    }
}
