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
    ///
    /// 优先恢复 currentProfile；它没有 token 时回退到列表里第一个有 token 的档案
    /// （登出 A 后 A 仍是 current，但 B 的 token 还有效——这时应该直接进 B 而不是弹登录页）。
    public init?(restoringFrom store: ServerStore) {
        let current = store.currentProfile
        let profile = current.flatMap { store.token(for: $0) != nil ? $0 : nil }
            ?? store.profiles.first { store.token(for: $0) != nil }
        guard let profile, let token = store.token(for: profile) else { return nil }
        self.init(
            profile: profile,
            client: Self.makeClient(baseURL: profile.baseURL, token: token)
        )
    }

    /// 按指定档案恢复会话（多服务器快速切换用）。token 缺失 / 会话对象建不出来时返回 nil，
    /// 由调用方决定回落到登录流程。
    public static func resume(
        profile: ServerProfile,
        from store: ServerStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) -> JellyfinServer? {
        guard let token = store.token(for: profile) else { return nil }
        return JellyfinServer(
            profile: profile,
            client: Self.makeClient(baseURL: profile.baseURL, token: token, sessionConfiguration: sessionConfiguration)
        )
    }

    static func makeClient(baseURL: URL, token: String?,
                           sessionConfiguration: URLSessionConfiguration = .default) -> JellyfinClient {
        // .default 是进程级共享单例，直接改会影响全 App 的会话；copy 一份再调。
        // request 30s：服务器半死时浏览 / PlaybackInfo 不干等默认 60s；
        // resource 300s：字幕 / 图片这类资源下载留足总时长（默认 7 天太宽）。
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return JellyfinClient(
            configuration: .init(
                url: baseURL,
                accessToken: token,
                client: ClientIdentity.clientName,
                deviceName: ClientIdentity.deviceName,
                deviceID: ClientIdentity.deviceID,
                version: ClientIdentity.version
            ),
            sessionConfiguration: configuration
        )
    }

    // MARK: - 登录

    /// 校验地址并创建登录会话。`urlString` 允许「192.168.1.10:8096」这种不带 scheme 的写法。
    /// `sessionConfiguration` 是测试注入口（塞 URLProtocol mock），业务代码不用传。
    ///
    /// Emby 的 API 固定挂在 `/emby` 前缀下（Jellyfin 在根路径）。探活先用原地址
    /// （Emby 对无前缀的 `/System/Info/Public` 同样响应），识别出 Emby 后会话与
    /// 落盘的 baseURL 都切到带 `/emby` 的地址——Get 拼 URL 保留子路径，一处前缀全链路生效。
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
            throw JellyfinError.wrapPreservingCancellation(error)
        }
        let kind = Self.detectKind(info: info)
        let resolvedBaseURL = kind == .emby ? Self.embyAPIBaseURL(from: url) : url
        let sessionClient = kind == .emby
            ? makeClient(baseURL: resolvedBaseURL, token: nil, sessionConfiguration: sessionConfiguration)
            : probeClient
        return LoginSession(baseURL: resolvedBaseURL, info: info, client: sessionClient, kind: kind)
    }

    /// 从探活结果判服务器类型。Emby 报 `ProductName`（如 "Emby Server"）且主版本是 4.x；
    /// Jellyfin 主版本是 10.x、通常不报 ProductName。
    static func detectKind(info: PublicSystemInfo) -> ServerKind {
        if let product = info.productName?.lowercased(), product.contains("emby") {
            return .emby
        }
        if let version = info.version, version.hasPrefix("4.") {
            return .emby
        }
        return .jellyfin
    }

    /// 给 Emby 地址追加 `/emby` API 前缀；已含该前缀则仅归一掉尾斜杠后返回。
    static func embyAPIBaseURL(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if !path.lowercased().hasSuffix("/emby") {
            path += "/emby"
        }
        components?.path = path
        return components?.url ?? url
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
    /// Emby 没有 `/UserViews` 新式路由，走老式 `/Users/{id}/Views`。
    public func userViews() async throws -> [MediaLibrary] {
        let request: Request<BaseItemDtoQueryResult>
        switch profile.kind {
        case .emby:
            request = Request(path: "/Users/\(profile.userID)/Views", method: "GET", id: "GetUserViews")
        case .jellyfin:
            request = Paths.getUserViews(parameters: .init(userID: profile.userID))
        }
        let result = try await send(request)
        return (result.items ?? [])
            .map { MediaLibrary(id: $0.id ?? UUID().uuidString, name: $0.name ?? "", collectionType: .init($0.collectionType?.rawValue)) }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }

    /// 首页「最近添加」。Emby 没有带 userId query 的新式 `/Items/Latest`，
    /// 走老式 `/Users/{id}/Items/Latest`（实测 Emby 4.10 对前者 404）。
    /// 两边返回的都是裸数组（非 QueryResult 信封）。
    public func latestItems(limit: Int = 24) async throws -> [MediaItem] {
        let request: Request<[BaseItemDto]>
        switch profile.kind {
        case .emby:
            request = Request<[BaseItemDto]>(
                path: "/Users/\(profile.userID)/Items/Latest",
                method: "GET",
                query: [
                    ("limit", String(limit)),
                    ("fields", "PrimaryImageAspectRatio"),
                    ("enableImageTypes", "Primary,Backdrop,Thumb"),
                ],
                id: "GetLatestMedia"
            )
        case .jellyfin:
            request = Request<[BaseItemDto]>(
                path: "/Items/Latest",
                method: "GET",
                query: [
                    ("userId", profile.userID),
                    ("includeItemTypes", "Movie,Series"),
                    ("enableImageTypes", "Primary,Backdrop,Thumb,Logo"),
                    ("limit", String(limit)),
                ],
                id: "GetLatestMedia"
            )
        }
        return try await send(request).map(\.domainItem)
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

    /// 首页「继续观看」。Emby 走老式 `/Users/{id}/Items/Resume`（Jellyfin 是 `/UserItems/Resume`）。
    public func resumeItems() async throws -> [MediaItem] {
        let request: Request<BaseItemDtoQueryResult>
        switch profile.kind {
        case .emby:
            request = Request(
                path: "/Users/\(profile.userID)/Items/Resume",
                method: "GET",
                query: [
                    ("limit", "24"),
                    ("mediaTypes", "Video"),
                    ("enableImageTypes", "Primary,Backdrop,Thumb,Logo"),
                ],
                id: "GetResumeItems"
            )
        case .jellyfin:
            request = Paths.getResumeItems(parameters: .init(
                userID: profile.userID,
                limit: 24,
                mediaTypes: [.video],
                enableImageTypes: [.primary, .backdrop, .thumb, .logo]
            ))
        }
        return try await send(request).items?.map(\.domainItem) ?? []
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

    /// 标记条目已看完（Jellyfin `POST /UserPlayedItems/{id}`；Emby 只有老式
    /// `POST /Users/{uid}/PlayedItems/{id}`，与 Views/Resume 同批旧路由）。
    /// 返回服务端最新的播放状态快照，便于 UI 就地更新。
    @discardableResult
    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        let request: Request<UserItemDataDto>
        switch profile.kind {
        case .emby:
            request = Request(
                path: "/Users/\(profile.userID)/PlayedItems/\(itemID)",
                method: "POST",
                query: [("userId", profile.userID)],
                id: "MarkPlayedItem"
            )
        case .jellyfin:
            request = Paths.markPlayedItem(itemID: itemID, userID: profile.userID)
        }
        let data = try await send(request)
        return data.domainPlayState
    }

    /// 取消已看标记（Jellyfin `DELETE /UserPlayedItems/{id}`；Emby 老式 DELETE）。
    @discardableResult
    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        let request: Request<UserItemDataDto>
        switch profile.kind {
        case .emby:
            request = Request(
                path: "/Users/\(profile.userID)/PlayedItems/\(itemID)",
                method: "DELETE",
                query: [("userId", profile.userID)],
                id: "MarkUnplayedItem"
            )
        case .jellyfin:
            request = Paths.markUnplayedItem(itemID: itemID, userID: profile.userID)
        }
        let data = try await send(request)
        return data.domainPlayState
    }

    /// 条目详情（含演员表 / 简介 / 流派）。
    /// 显式带 `fields`：部分服务器版本默认不返回 People 等扩展字段（SDK 自带的
    /// `Paths.getItem` 不带 fields），显式请求两边都稳。
    /// Emby 没有 `/Items/{id}` 新式路由，走老式 `/Users/{uid}/Items/{id}`。
    public func item(_ id: String) async throws -> MediaItem {
        let request = Request<BaseItemDto>(
            path: detailPath(itemID: id),
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
            path: detailPath(itemID: itemID),
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

    /// 条目详情路径：Jellyfin `/Items/{id}` + userId query；Emby `/Users/{uid}/Items/{id}`。
    private func detailPath(itemID: String) -> String {
        switch profile.kind {
        case .emby: "/Users/\(profile.userID)/Items/\(itemID)"
        case .jellyfin: "/Items/\(itemID)"
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
    ///
    /// 统一两段式解码：原始 data → sanitizer 洗白（Emby 的杂枚举值 /
    /// 缺 Key 的 UserData）→ SDK 解码。对 Jellyfin 标准响应洗白是无害透传；
    /// 好处是 Items/Similar/Seasons/Episodes 等全部接口一处覆盖，不用逐个分叉。
    func send<T: Decodable & Sendable>(_ request: Request<T>) async throws -> T {
        let path = NetworkLog.logPath(for: request.url)
        let start = Date()
        do {
            // data(for:) 返回原始响应体（已经过 client 的 2xx 校验 + 认证头注入），
            // 洗白后用与 SDK 相同配置的 decoder 二次解码。
            let response = try await client.data(for: request)
            // sanitizer 是全量 JSON 重解析 + 递归深拷贝重建，纯 Jellyfin 响应没理由
            // 每个请求都付这笔账：只有 Emby 档案无条件洗；其余档案先直接解码，
            // 失败再回退洗白（个别自建 Jellyfin 也会有 Emby 式脏枚举值）。
            let payload = response.value
            let value: T
            if profile.kind == .emby {
                value = try LooseDecoding.decoder.decode(T.self, from: EmbySanitizer.sanitize(payload))
            } else {
                do {
                    value = try LooseDecoding.decoder.decode(T.self, from: payload)
                } catch {
                    value = try LooseDecoding.decoder.decode(T.self, from: EmbySanitizer.sanitize(payload))
                }
            }
            NetworkLog.requestSucceeded(path, duration: Date().timeIntervalSince(start))
            return value
        } catch {
            NetworkLog.requestFailed(path, error: error, duration: Date().timeIntervalSince(start))
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }

    /// 原始响应发送口：响应体不进解码，交给调用方宽松处理。
    /// 错误分类 / 日志语义由 `send` 统一承担。
    func sendRaw(_ request: Request<Data>) async throws -> Data {
        let path = NetworkLog.logPath(for: request.url)
        do {
            return try await client.send(request).value
        } catch {
            NetworkLog.requestFailed(path, error: error, duration: 0)
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }
}

// MARK: - 登录会话

/// 登录成功的产出（对 `AuthenticationResult` 的收口：App 层不 import JellyfinAPI）。
public struct LoginResult: Sendable {
    public let token: String
    public let userID: String
    public let userName: String?

    /// 宽松解码路径（`LoginSession.parseLoginResponse`）直接构造。
    init(token: String, userID: String, userName: String?) {
        self.token = token
        self.userID = userID
        self.userName = userName
    }

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
    /// Emby 登录后 client/baseURL 已带 `/emby` 前缀；Jellyfin 即原始地址。
    public let kind: ServerKind
    let serverID: String?
    let client: JellyfinClient

    init(baseURL: URL, info: PublicSystemInfo, client: JellyfinClient, kind: ServerKind) {
        self.baseURL = baseURL
        self.serverName = info.serverName ?? "Jellyfin"
        self.serverVersion = info.version
        self.serverID = info.id
        self.client = client
        self.kind = kind
    }

    /// Quick Connect 是 Jellyfin 自己的实现，Emby 没有这个端点；
    /// UI 与登录流程按这个开关隐藏 / 跳过 QC。
    public var supportsQuickConnect: Bool { kind == .jellyfin }

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
                        continuation.finish(throwing: JellyfinError.wrapPreservingCancellation(error))
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
    ///
    /// 密码错误的 HTTP 状态码 Jellyfin 是 401/403，Emby 老版本可能是 400；
    /// 登录场景下把 400 也归成「账号密码不对」的提示，避免报成莫名的 HTTP 400。
    ///
    /// **响应体走宽松解码**（只抽 AccessToken / User.Id / User.Name），不复用 SDK 的
    /// `AuthenticationResult`：Emby 的 User 对象里带 Jellyfin schema 没有的字段
    /// （如 UserPolicy 变体），强类型解码会整包炸出 "The data couldn't be read
    /// because it is missing"，而登录只需要这三样。失败状态码维持 validate 语义。
    public func signIn(username: String, password: String) async throws -> LoginResult {
        do {
            let request = Request<Data>(
                path: "/Users/AuthenticateByName",
                method: "POST",
                body: LoginRequestBody(username: username, password: password),
                id: "AuthenticateUserByName"
            )
            let data = try await client.send(request).value
            return try Self.parseLoginResponse(data)
        } catch let error as JellyfinError {
            throw error
        } catch APIError.unacceptableStatusCode(400) {
            throw JellyfinError(.unauthorized)
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }

    private struct LoginRequestBody: Encodable {
        let username: String
        let password: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(username, forKey: .username)
            // Jellyfin/Emby 的约定字段名就是 Pw。
            try container.encode(password, forKey: .pw)
        }

        enum CodingKeys: String, CodingKey {
            case username = "Username"
            case pw = "Pw"
        }
    }

    /// 从登录响应原始 JSON 抽必要字段；多余字段与类型波动全部忽略。
    ///
    /// Emby / Jellyfin 的顶层和 User 对象字段名一致（AccessToken / User.Id），
    /// 只做「拿到什么算什么」的容错：类型不对的字段当 nil 处理，不炸整包。
    static func parseLoginResponse(_ data: Data) throws -> LoginResult {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw JellyfinError(.unauthorized)
        }
        guard let token = Self.nonEmptyString(dict["AccessToken"]) else {
            // 没带 token 的"成功"响应等于没登录成。
            throw JellyfinError(.unauthorized)
        }
        let user = dict["User"] as? [String: Any]
        let userID = user.flatMap { Self.nonEmptyString($0["Id"]) }
        let userName = user.flatMap { $0["Name"] as? String }
        guard let userID else {
            throw JellyfinError(.unauthorized)
        }
        return LoginResult(token: token, userID: userID, userName: userName)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func signIn(quickConnectSecret: String) async throws -> LoginResult {
        do {
            return try LoginResult(await client.signIn(quickConnectSecret: quickConnectSecret))
        } catch let error as JellyfinError {
            throw error
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
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
            serverVersion: serverVersion,
            kind: kind
        )
        store.activate(profile, token: result.token)
        return JellyfinServer(profile: profile, client: Self.makeAuthedClient(baseURL: baseURL, token: result.token))
    }

    private static func makeAuthedClient(baseURL: URL, token: String) -> JellyfinClient {
        JellyfinServer.makeClient(baseURL: baseURL, token: token)
    }
}
