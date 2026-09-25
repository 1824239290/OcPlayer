import CoreModel
import DiagnosticsKit
import Foundation
import Get
import JellyfinAPI

/// 网络层诊断日志（JSONL 落盘 + OSLog 镜像，见 DiagnosticsKit）。
///
/// 只记请求**路径**不记 query（userId / 图片 tag 这类不敏感，但路径足够定位问题）；
/// 任何 token 都由红actor 兜底，绝不进日志。实现委托 DiagnosticsKit.NetworkLog
/// （本文件 enum 与共享类型同名，需限定前缀）。
enum NetworkLog {
    private static let category = "Jellyfin"

    /// ServerStore 等直接写日志用（共享分类 logger，与请求日志同一实例同一文件）。
    static let logger = DiagnosticsKit.NetworkLog.logger(category: "Jellyfin")

    static func requestSucceeded(_ path: String, duration: TimeInterval, level: DiagnosticLevel = .debug) {
        DiagnosticsKit.NetworkLog.requestSucceeded(category: category, path: path, duration: duration, level: level)
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        DiagnosticsKit.NetworkLog.requestFailed(category: category, path: path, error: error, duration: duration)
    }

    /// Emby 的裸传输层用自己那一档分类（诊断日志按服务器产品分文件，排障时能直接
    /// 定位到是哪台服务器出的问题）。
    enum Emby {
        private static let category = "Emby"

        static func requestSucceeded(_ path: String, duration: TimeInterval, level: DiagnosticLevel = .info) {
            DiagnosticsKit.NetworkLog.requestSucceeded(category: category, path: path, duration: duration, level: level)
        }

        static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
            DiagnosticsKit.NetworkLog.requestFailed(category: category, path: path, error: error, duration: duration)
        }
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
///
/// Emby 不走这里：它由 `EmbyServer` 用裸 HTTP 实现同一条 `MediaServer` 契约。
/// 分家的理由见 `MediaServer` 的文档注释（解码契约不兼容）。
public struct JellyfinServer: MediaServer {
    public let profile: ServerProfile
    public let client: JellyfinClient

    public var accessToken: String? { client.accessToken }

    init(profile: ServerProfile, client: JellyfinClient) {
        self.profile = profile
        self.client = client
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
        // 登录 / 探活阶段的 UA（会话创建时刻的偏好值）；已登录会话的每条请求在
        // `send` 里按**当时**的偏好重设，设置里改完即时生效。
        // 合并而不是整体赋值：调用方传进来的 sessionConfiguration 可能自带
        // 额外的 httpAdditionalHeaders，直接赋值会静默吃掉它们。
        if let userAgent = ClientIdentity.customUserAgent {
            var additionalHeaders = configuration.httpAdditionalHeaders ?? [:]
            additionalHeaders["User-Agent"] = userAgent
            configuration.httpAdditionalHeaders = additionalHeaders
        }
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

    // MARK: - 浏览

    /// 用户的媒体库列表（电影 / 剧集 / 音乐…）。
    public func userViews() async throws -> [MediaLibrary] {
        let result = try await send(Paths.getUserViews(parameters: .init(userID: profile.userID)))
        return (result.items ?? [])
            .map { MediaLibrary(id: $0.id ?? UUID().uuidString, name: $0.name ?? "", collectionType: .init($0.collectionType?.rawValue)) }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }

    /// 首页「最近添加」。返回的是裸数组（非 QueryResult 信封）。
    public func latestItems(limit: Int = 24) async throws -> [MediaItem] {
        try await send(
            Request<[BaseItemDto]>(
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

    /// 首页氛围背景取材：全库随机一批带 backdrop 的电影 / 剧集。
    /// `SortBy=Random` Emby/Jellyfin 双端都支持；hasBackdrop 服务端过滤差异大，
    /// 拿回来后按 tag 过滤兜底，数量不够由调用方自行回退（如首页已加载条目）。
    public func randomBackdropItems(limit: Int = 24) async throws -> [MediaItem] {
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                limit: limit,
                isRecursive: true,
                includeItemTypes: [.movie, .series],
                sortBy: [.random],
                enableImageTypes: [.primary, .backdrop]
            ))
        )
        return (result.items?.map(\.domainItem) ?? []).filter { $0.backdropImageTag != nil }
    }

    /// 标记条目已看完（Jellyfin `POST /UserPlayedItems/{id}`；Emby 只有老式
    /// `POST /Users/{uid}/PlayedItems/{id}`，与 Views/Resume 同批旧路由）。
    /// 返回服务端最新的播放状态快照，便于 UI 就地更新。
    @discardableResult
    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        try await send(Paths.markPlayedItem(itemID: itemID, userID: profile.userID)).domainPlayState
    }

    /// 取消已看标记（Jellyfin `DELETE /UserPlayedItems/{id}`；Emby 老式 DELETE）。
    @discardableResult
    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        try await send(Paths.markUnplayedItem(itemID: itemID, userID: profile.userID)).domainPlayState
    }

    /// 条目详情（含演员表 / 简介 / 流派）。
    /// 显式带 `fields`：部分服务器版本默认不返回 People 等扩展字段（SDK 自带的
    /// `Paths.getItem` 不带 fields），显式请求更稳。
    public func item(_ id: String) async throws -> MediaItem {
        try await send(
            Request<BaseItemDto>(
                path: "/Items/\(id)",
                query: [
                    ("userId", profile.userID),
                    ("fields", "People,Genres,Overview,Chapters"),
                ]
            )
        )
        .domainItem
    }

    /// 拉取条目的章节列表(`BaseItemDto.chapters`)。
    /// 与 `item(id:)` 走同一个 `Chapters` field,但省掉 People / 演员等无关数据。
    public func chapters(itemID: String) async throws -> [JellyfinChapter] {
        let dto = try await send(
            Request<BaseItemDto>(
                path: "/Items/\(itemID)",
                query: [
                    ("userId", profile.userID),
                    ("fields", "Chapters"),
                ]
            )
        )
        return (dto.chapters ?? []).enumerated().map { index, info in
            JellyfinChapter(info, index: index)
        }
    }

    /// 媒体库单页浏览。`limit` 只表示本页大小，不会自动翻到 TotalRecordCount。
    /// `sort` 传 nil 时保持历史行为（按名称升序）；方向与主键在服务端生效，
    /// 副键固定名称升序，返回顺序即请求顺序。`watchState` 为 watched / unwatched
    /// 时加服务端 isPlayed / isUnplayed 过滤，nil / all 不过滤。
    public func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]? = nil,
        recursive: Bool = true,
        startIndex: Int = 0,
        limit: Int = 100,
        sort: MediaItemsSort? = nil,
        watchState: MediaItemsWatchState? = nil,
        searchTerm: String? = nil
    ) async throws -> MediaItemsPage {
        let pageSize = max(limit, 1)
        let pageStart = max(startIndex, 0)
        let (sortKeys, sortOrders) = sort.map { $0.rawKeysAndOrders() } ?? (["SortName"], ["Ascending"])
        let itemFilters: [ItemFilter]?
        switch watchState {
        case .watched: itemFilters = [.isPlayed]
        case .unwatched: itemFilters = [.isUnplayed]
        case .all, nil: itemFilters = nil
        }
        let trimmedSearch = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                startIndex: pageStart,
                limit: pageSize,
                isRecursive: recursive,
                searchTerm: (trimmedSearch?.isEmpty == false) ? trimmedSearch : nil,
                sortOrder: sortOrders.compactMap(SortOrder.init(rawValue:)),
                parentID: parentID,
                includeItemTypes: kinds.map { kinds in
                    kinds.compactMap { kind in BaseItemKind(kind) }
                },
                filters: itemFilters,
                sortBy: sortKeys.compactMap(ItemSortBy.init(rawValue:)),
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
        // 硬上限：totalRecordCount 异常（nil 恒缺 / 数字畸大）时防无限翻页。
        let hardLimit = 10_000

        while loaded.count < hardLimit {
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
        return loaded
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
    /// 直接走 SDK 的类型化解码：SDK 的 DTO 值域就是 Jellyfin 的值域，强解不会
    /// 失败。Emby 不经过这里 —— 它的响应值域超出 SDK 枚举，由 `EmbyServer` 的
    /// 裸传输层自己宽松解码（见 `MediaServer` 的文档注释）。
    func send<T: Decodable & Sendable>(_ request: Request<T>) async throws -> T {
        var request = request
        if let userAgent = ClientIdentity.customUserAgent {
            request.headers = (request.headers ?? [:]).merging(["User-Agent": userAgent]) { _, new in new }
        }
        let path = NetworkLog.logPath(for: request.url)
        let start = Date()
        do {
            let value = try await client.send(request).value
            NetworkLog.requestSucceeded(path, duration: Date().timeIntervalSince(start), level: .info)
            return value
        } catch {
            NetworkLog.requestFailed(path, error: error, duration: Date().timeIntervalSince(start))
            let wrapped = JellyfinError.wrapPreservingCancellation(error)
            await notifyIfTokenExpired(wrapped)
            throw wrapped
        }
    }


    /// 鉴权 API 上的 401 = token 失效且包内没有重登兜底（对比 MoviePilot 的
    /// silentRelogin）——发通知把 UI 拉回重登流程，别让后续请求持续裸报
    /// `.unauthorized`。主线程投递（App 侧 .onReceive 在主线程收）。
    private func notifyIfTokenExpired(_ error: any Error) async {
        guard let jellyfinError = error as? JellyfinError,
              case .unauthorized = jellyfinError.kind
        else { return }
        let profileID = profile.id
        await MainActor.run {
            NotificationCenter.default.post(
                name: MediaServerAuthentication.authenticationRequired,
                object: profileID)
        }
    }
}
