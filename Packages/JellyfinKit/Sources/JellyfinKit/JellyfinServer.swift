import CoreModel
import DiagnosticsKit
import Foundation
import Get
import JellyfinAPI

/// 连接服务器时用户显式选择的网络协议。
/// 存到 `baseURL` 里作为唯一事实源:Jellyfin API、图片、播放流全部从这里派生。
public enum JellyfinServerScheme: String, Sendable {
    case http
    case https

    /// 落进绝对 URL 的 scheme 文本。
    public var schemeString: String { rawValue }

    public init?(schemeString value: String) {
        self.init(rawValue: value.lowercased())
    }
}

/// 网络层诊断日志（JSONL 落盘 + OSLog 镜像，见 DiagnosticsKit）。
///
/// 只记请求**路径**不记 query（userId / 图片 tag 这类不敏感，但路径足够定位问题）；
/// 任何 token 都由红actor 兜底，绝不进日志。实现委托 DiagnosticsKit.NetworkLog
/// （本文件 enum 与共享类型同名，需限定前缀）。
enum NetworkLog {
    private static let category = "Jellyfin"

    /// ServerStore 等直接写日志用（共享分类 logger，与请求日志同一实例同一文件）。
    static let logger = DiagnosticsKit.NetworkLog.logger(category: "Jellyfin")

    static func requestStarted(_ path: String) {
        DiagnosticsKit.NetworkLog.requestStarted(category: category, path: path)
    }

    static func requestSucceeded(_ path: String, duration: TimeInterval) {
        DiagnosticsKit.NetworkLog.requestSucceeded(category: category, path: path, duration: duration)
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        DiagnosticsKit.NetworkLog.requestFailed(category: category, path: path, error: error, duration: duration)
    }

    /// 进度上报这类「尽力而为」的失败：不打断播放，但值得留一条 warning。
    static func reportFailed(_ what: String, error: Error) {
        DiagnosticsKit.NetworkLog.report(category: category, level: .warning, "上报失败 what=\(what) error=\(error)")
    }

    /// `Request.url` 形如 `/Items?userId=…`，只取 path 部分入日志。
    static func logPath(for url: URL?) -> String {
        DiagnosticsKit.NetworkLog.logPath(for: url)
    }
}

/// 条目图片类型（对 Jellyfin `ImageType` 的收口，避免 JellyfinAPI 类型漏出包外）。
public enum ItemImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
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
        preferredScheme: JellyfinServerScheme? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> LoginSession {
        let url = try normalizeServerURL(rawURL, preferredScheme: preferredScheme)

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

    /// 「host:port」→「scheme://host:port/」(去尾斜杠),统一成确定性的 scheme。
    /// 优先级：**用户手写的 `http(s)://` 前缀 > `preferredScheme` > 默认 http**。
    public static func normalizeServerURL(
        _ raw: String,
        preferredScheme: JellyfinServerScheme? = nil
    ) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinError(.badServerURL) }
        if text.range(of: "://") == nil {
            // 没手写前缀才用 preferredScheme;都没有回退 http(局域网部署为主)。
            text = (preferredScheme?.schemeString ?? "http") + "://" + text
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
                enableImageTypes: [.primary, .backdrop, .logo],
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
                enableImageTypes: [.primary, .backdrop, .logo]
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
                mediaTypes: [.video],
                enableImageTypes: [.primary, .backdrop, .thumb, .logo]
            ))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 「接下来看」：追剧下一集。
    public func nextUp() async throws -> [MediaItem] {
        try await send(
            Paths.getNextUp(parameters: .init(
                userID: profile.userID,
                limit: 24,
                enableImageTypes: [.primary, .backdrop, .thumb, .logo]
            ))
        )
        .items?.map(\.domainItem) ?? []
    }

    /// 标记条目已看完（Jellyfin `POST /UserPlayedItems/{id}`）。
    /// 返回服务端最新的播放状态快照，便于 UI 就地更新。
    @discardableResult
    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        let data = try await send(
            Paths.markPlayedItem(itemID: itemID, userID: profile.userID)
        )
        return data.domainPlayState
    }

    /// 取消已看标记（Jellyfin `DELETE /UserPlayedItems/{id}`）。
    @discardableResult
    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        let data = try await send(
            Paths.markUnplayedItem(itemID: itemID, userID: profile.userID)
        )
        return data.domainPlayState
    }

    /// 条目详情（含演员表 / 简介 / 流派）。
    /// 显式带 `fields`：部分服务器版本默认不返回 People 等扩展字段（SDK 自带的
    /// `Paths.getItem` 不带 fields），显式请求两边都稳。
    public func item(_ id: String) async throws -> MediaItem {
        let request = Request<BaseItemDto>(
            path: "/Items/\(id)",
            query: [
                ("userId", profile.userID),
                ("fields", "People,Genres,Overview,Chapters"),
            ]
        )
        return try await send(request).domainItem
    }

    /// 拉取条目的章节列表(`BaseItemDto.chapters`)。
    /// 与 `item(id:)` 走同一个 `Chapters` field,但省掉 People / 演员等无关数据。
    public func chapters(itemID: String) async throws -> [JellyfinChapter] {
        let request = Request<BaseItemDto>(
            path: "/Items/\(itemID)",
            query: [
                ("userId", profile.userID),
                ("fields", "Chapters"),
            ]
        )
        let dto = try await send(request)
        return (dto.chapters ?? []).enumerated().map { index, info in
            JellyfinChapter(info, index: index)
        }
    }

    /// 媒体库单页结果。`totalRecordCount` 来自服务端；未知时为 nil。
    public struct MediaItemsPage: Sendable, Equatable {
        public var items: [MediaItem]
        public var startIndex: Int
        public var totalRecordCount: Int?

        public init(items: [MediaItem], startIndex: Int, totalRecordCount: Int?) {
            self.items = items
            self.startIndex = startIndex
            self.totalRecordCount = totalRecordCount
        }

        /// 是否还能向后翻页（总数未知时以本页是否满页为准）。
        public var hasMore: Bool {
            if let totalRecordCount {
                return startIndex + items.count < totalRecordCount
            }
            return !items.isEmpty
        }
    }

    /// 媒体库单页浏览。`limit` 只表示本页大小，不会自动翻到 TotalRecordCount。
    public func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]? = nil,
        recursive: Bool = true,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> MediaItemsPage {
        let pageSize = max(limit, 1)
        let pageStart = max(startIndex, 0)
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                startIndex: pageStart,
                limit: pageSize,
                isRecursive: recursive,
                parentID: parentID,
                includeItemTypes: kinds.map { kinds in
                    kinds.compactMap { kind in BaseItemKind(kind) }
                },
                sortBy: [.sortName],
                enableImageTypes: [.primary, .backdrop, .logo],
                enableTotalRecordCount: true
            ))
        )
        let page = result.items?.map(\.domainItem) ?? []
        return MediaItemsPage(
            items: page,
            startIndex: pageStart,
            totalRecordCount: result.totalRecordCount
        )
    }

    /// 媒体库网格浏览（拉全部分页）。`recursive` = true 时直接铺到叶子（电影库 → 所有电影）。
    /// `limit` 是单页大小；会按 `TotalRecordCount` 继续请求直到取完。
    /// UI 大库场景请优先用 `itemsPage`，避免一次进内存。
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
            let page = try await itemsPage(
                parentID: parentID,
                kinds: kinds,
                recursive: recursive,
                startIndex: startIndex,
                limit: pageSize
            )
            loaded.append(contentsOf: page.items)

            if page.items.isEmpty
                || page.totalRecordCount.map({ loaded.count >= $0 }) == true
                || (page.totalRecordCount == nil && page.items.count < pageSize) {
                return loaded
            }
            startIndex += page.items.count
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
                enableImageTypes: [.primary, .thumb, .logo],
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

    /// 连播用：从 `startItemID` 这一集起，按服务端的剧集顺序最多取 `limit` 条
    /// （**含它自己**）。跨季自然衔接，不用把整部剧的集列表拉回来——长番几百集，
    /// 每次开播都拉全量纯属浪费。
    ///
    /// 返回值保持**服务端顺序**，不再本地重排：`startItemId` 的语义就是
    /// 「在服务端那份顺序里跳到这一条」，本地按 (季号, 集号) 重排会把夹在
    /// 窗口里的第 0 季特典挪到当前集前面，"往后取一条"就取错了。
    public func episodes(
        seriesID: String,
        startingAt startItemID: String,
        limit: Int
    ) async throws -> [MediaItem] {
        try await send(
            Paths.getEpisodes(seriesID: seriesID, parameters: .init(
                userID: profile.userID,
                startItemID: startItemID,
                limit: limit,
                enableImages: true,
                enableImageTypes: [.primary, .thumb, .logo],
                enableUserData: true,
                sortBy: .indexNumber
            ))
        )
        .items?.map(\.domainItem) ?? []
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
        guard var components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinError(.other("播放地址拼接失败"))
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = "\(basePath)/Videos/\(itemID)/stream"
        var queryItems = [URLQueryItem(name: "Static", value: "true")]
        if let mediaSourceID {
            queryItems.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceID))
        }
        if let playSessionID {
            queryItems.append(URLQueryItem(name: "playSessionId", value: playSessionID))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
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
        AsyncThrowingStream { continuation in
            let upstream = client.quickConnect.connect(poll: 3, max: 60)
            let task = Task {
                do {
                    for try await event in upstream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if case let APIError.unacceptableStatusCode(status) = error, status == 404 {
                        continuation.finish(throwing: JellyfinError(.quickConnectDisabled, underlying: error))
                    } else if let jellyfinError = error as? JellyfinError, case .http(404) = jellyfinError.kind {
                        continuation.finish(throwing: JellyfinError(.quickConnectDisabled, underlying: jellyfinError.underlying ?? error))
                    } else {
                        continuation.finish(throwing: JellyfinError.wrap(error))
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
