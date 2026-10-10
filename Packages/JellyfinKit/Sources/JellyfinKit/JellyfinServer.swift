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
    /// 会话是**引用类型**，而且必须如此：`JellyfinClient` 的 baseURL 钉在它的
    /// `Configuration` 里（`let`），换地址只能重建客户端，struct 存不下这份
    /// 「按地址缓存的客户端」状态。
    let session: JellyfinSession

    init(session: JellyfinSession) {
        self.session = session
    }

    /// 固定单一客户端的构造口（测试、以及还没有档案的探活阶段）：地址永不切换。
    init(profile: ServerProfile, client: JellyfinClient) {
        self.session = JellyfinSession(profile: profile, fixedClient: client)
    }

    /// 当前生效地址（跟着决议器走，见 `ServerEndpointDirectory`）。
    public var profile: ServerProfile { session.profile }
    public var accessToken: String? { session.accessToken }
    /// 当前生效地址对应的 SDK 客户端。
    public var client: JellyfinClient { session.client }

    /// 按指定档案恢复会话（多服务器快速切换用）。token 缺失 / 会话对象建不出来时返回 nil，
    /// 由调用方决定回落到登录流程。
    ///
    /// 会话挂上 store 托管的**地址决议器**：同一台服务器的局域网 / Tailscale 地址
    /// 由它探活择优，请求层不必知道用的是哪条。
    public static func resume(
        profile: ServerProfile,
        from store: ServerStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) -> JellyfinServer? {
        guard let token = store.token(for: profile) else { return nil }
        let directory = store.endpointDirectory(for: profile, sessionConfiguration: sessionConfiguration)
        directory.setAuthorizationHeader(ClientIdentity.mediaBrowserAuthorizationHeader(token: token))
        return JellyfinServer(
            session: JellyfinSession(
                profile: profile,
                token: token,
                directory: directory,
                sessionConfiguration: sessionConfiguration
            )
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
            .map {
                MediaLibrary(
                    id: $0.id ?? UUID().uuidString,
                    name: $0.name ?? "",
                    collectionType: .init($0.collectionType?.rawValue),
                    primaryImageTag: $0.imageTags?["Primary"]
                )
            }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }

    /// 首页「最近添加」：最近入库的电影 / 剧集，服务端按入库时间倒序。
    ///
    /// **刻意不用 `/Items/Latest`**——Jellyfin **12.1.0** 上该端点一旦带
    /// `includeItemTypes` 就恒返回空数组。2026-10-07 对 12.1.0 实测（同一账号、
    /// 同一台服务器）：`/Items/Latest?userId=…&includeItemTypes=Movie,Series&limit=24`
    /// → `[]`，**HTTP 200**；同一个请求去掉 `includeItemTypes` 才返回内容；
    /// 换成 `Movie` / `Series` / 小写 / 合并写法结果一样空。空数组是「成功值」，
    /// 所以症状是首页「最近添加」整条**静默**消失——连 `rail 加载失败` 都不打。
    ///
    /// 补 `groupItems=false` 能让它出内容，但**会漏条目**（同一次实测：15 条 vs
    /// `/Items` 的 43 条，连「刚入库两天」的条目都不在里面），所以这不是「少个参数」
    /// 能修的病，而是该换端点。
    ///
    /// `/Items` + `DateCreated` 倒序是本机 12.1.0 实测正常的口径，也是本文件
    /// `favoriteItems` 与库页「排序 = 最近添加」（`MediaItemsSortField.dateAdded`）
    /// 一直在用的写法；10.x 起就稳定，比 12.x 的 Latest 保守。`isRecursive` 必需
    /// （默认 false 时只返回顶层项）。注意返回的是信封 `BaseItemDtoQueryResult`，
    /// 与 Emby 侧老式路由的裸数组不同。
    public func latestItems(limit: Int = 24) async throws -> [MediaItem] {
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                limit: limit,
                isRecursive: true,
                sortOrder: [.descending],
                fields: [.primaryImageAspectRatio],
                includeItemTypes: [.movie, .series],
                sortBy: [.dateCreated],
                enableImageTypes: [.primary, .backdrop, .logo]
            ))
        )
        return result.items?.map(\.domainItem) ?? []
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
                fields: [.primaryImageAspectRatio],
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
                fields: [.primaryImageAspectRatio],
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
                fields: [.primaryImageAspectRatio],
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
                    ("fields", "People,Genres,Overview,Chapters,PrimaryImageAspectRatio"),
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
                // 显式要 `ProviderIds`：**列表接口默认不返回它**（实测本机
                // Jellyfin 12.1.0：`/Items` 不带 fields 时 0/5 个条目有
                // `ProviderIds`，而 `/Items/{id}` 默认就有）。缺了它的 `MediaItem`
                // 没有 `tmdbID`，TMDb 匹配就只能退化成标题搜索——库级批量补全全靠
                // 这个字段。体积上它只是个小字典。
                //
                // `primaryImageAspectRatio`：海报卡要「边框贴着图片」就不能假设 2:3
                // ——实测本机库里 0.667 / 0.70 / 0.75 三种都有，比例必须从服务端拿
                // （拿不到就得先按兜底比例排一遍再跳，见 `MediaArtwork`）。
                // 列表接口**默认不返回**它（实测 `/Items` 不带 fields 时 0/12 带比例），
                // 所以必须显式要。
                //
                // 位置有讲究：SDK 的 `init` 要求 `fields` 排在 `includeItemTypes`
                // **之前**（Swift 实参顺序必须与声明一致）。
                fields: [.providerIDs, .primaryImageAspectRatio],
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
    ///
    /// 地址用**当前生效**那条（决议器选的）：内核拿到哪条就走哪条，
    /// 与浏览 / 图片同源，不会出现「界面在 Tailscale 上、流还指着局域网」。
    public func streamURL(
        itemID: String,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil
    ) throws -> String {
        var query = [("Static", "true")]
        if let mediaSourceID { query.append(("mediaSourceId", mediaSourceID)) }
        if let playSessionID { query.append(("playSessionId", playSessionID)) }
        return try ServerURL.absolute(
            base: session.activeURL,
            path: "/Videos/\(itemID)/stream",
            query: query
        ).absoluteString
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
        // 首启 / 网络变化后这里会等一次探活（几百毫秒量级）；平时是同步读缓存。
        _ = await session.resolvedURL()
        // 幂等的浏览类请求（GET）做退避重试，写操作不重试。
        //
        // 此前本包**完全没有重试**：服务器半死（回 502/503 或连接被掐）时，用户只能
        // 看着首页转圈到超时。共享的 `RetryPolicy` 在 DiagnosticsKit 里早就有
        // （Bangumi / MoviePilot 都在用），这边只是没接上。
        //
        // 只对幂等请求生效是刻意的：浏览 / 详情 / 章节 / 上报会话都是 GET（重放安全），
        // 而 `markPlayed` / `markUnplayed` 不是——重放会把一次用户操作变成两次。
        // 与 MoviePilotKit 那条「非幂等不重试」是同一条规则。
        let policy = Self.isIdempotent(request.method) ? Self.browseRetryPolicy : Self.noRetryPolicy
        var lastError: (any Error)?
        let overallStart = Date()
        for attempt in 1...policy.attempts {
            let client = session.client
            let address = client.configuration.url
            let start = Date()
            do {
                let value = try await client.send(request).value
                NetworkLog.requestSucceeded(path, duration: Date().timeIntervalSince(start), level: .info)
                return value
            } catch {
                let wrapped = JellyfinError.wrapPreservingCancellation(error)
                // 取消照抛：那是"调用方不要了"，不是可重试的失败。
                if JellyfinError.isCancellation(error) { throw wrapped }
                lastError = wrapped
                // ⚠️ 换址判断必须排在下面的重试闸门**之前**。
                //
                // `.serverUnreachable` 里混着两类底层原因：「解析得到但连不上」
                // （-1004/-1005，`isRetryable` 为 true）与「名字解析不了」
                // （-1003/-1006，`isRetryable` 为 false）。而主机名候选
                // （`nas.local` / 单标签 `nas` / MagicDNS 名 / 反代域名）在换到别的
                // 网络后报的恰恰是后者 —— 若先过重试闸门，`break` 会把换址一起吃掉：
                // 一次请求只发一次、不换址、不重试，而且 `resolvedAt` 仍是「新鲜」
                // 的旧结论，后续请求继续走同一条死地址，最长拖到缓存过期（300s）。
                // 「出门自动换到 Tailscale」正好就是这一类地址，所以这不是边角。
                if let jellyfinError = wrapped as? JellyfinError, jellyfinError.isAddressFailure,
                   attempt < policy.attempts, await session.failover(from: address) {
                    NetworkLog.logger.info(
                        "地址不可用，换地址后重试 \(request.method.rawValue) \(path)",
                        fields: ["from": .string(address.absoluteString),
                                 "to": .string(session.activeURL.absoluteString)])
                    continue
                }
                guard attempt < policy.attempts, Self.isRetryable(wrapped) else { break }
                let delay = policy.backoffNanoseconds(attempt: attempt)
                // ⚠️ 用 `.info` 而不是 `.debug`：默认档只落 info 及以上（见
                // `DiagnosticsSettings.apply`），而「重试发生了」恰恰是排查
                // 「首页转圈 / 背景不出来」时唯一能证明瞬态失败已自愈的证据。
                // 用 debug 的话，用户报障时导出的诊断包里根本看不到它。
                NetworkLog.logger.info(
                    "重试 \(request.method.rawValue) \(path)（第 \(attempt + 1)/\(policy.attempts) 次）",
                    fields: ["attempt": .integer(Int64(attempt + 1))])
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        let finalError = lastError ?? JellyfinError(.other("请求失败"))
        NetworkLog.requestFailed(path, error: finalError, duration: Date().timeIntervalSince(overallStart))
        await notifyIfTokenExpired(finalError)
        throw finalError
    }

    /// 浏览类请求的重试预算：3 次（含首发）足以扛过 502/503 与瞬时断连。
    /// 再加只会让用户等更久——底层单次超时本身已是 30 秒级。
    ///
    /// 用 `static var`（而非 `let`）只为让测试能换成「预算 2 + 退避近零」的版本，
    /// 从而在不必真等几秒的前提下验证「重试确实发生了」。生产路径只读不写。
    nonisolated(unsafe) static var browseRetryPolicy = RetryPolicy(attempts: 3)
    /// 写操作用它，也就是"不重试"。
    nonisolated(unsafe) static var noRetryPolicy = RetryPolicy(attempts: 1)

    /// 幂等判定：按 HTTP 语义（与 MoviePilotKit 的 `MPRequest.isIdempotent` 同口径）。
    static func isIdempotent(_ method: HTTPMethod) -> Bool {
        switch method.rawValue.uppercased() {
        case "GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE":
            return true
        default:
            return false
        }
    }

    /// 值得重试的错误：传输层瞬态（超时 / 断连）与 5xx、429。
    /// 4xx（除 429）是请求本身的问题，重试只会白撞。
    ///
    /// 入参是 `any Error`（`wrapPreservingCancellation` 保留取消原样抛出的类型），
    /// 非 `JellyfinError` 一律不重试。
    ///
    /// ⚠️ 判据是「**名字解析不了 = 永久，解析得到但连不上 = 瞬态**」。
    /// 这里的教训来自实机日志：`.serverUnreachable` 原先把 `-1009 本机没网`
    /// 和"地址写错"混在一起，于是冷启动时（网络还没就绪）五个请求全部不重试、
    /// 直接失败；而网络就绪后同样的请求 85–583 ms 全部成功。
    /// 现在 `-1009` 单独归 `.noNetwork` 且可重试。
    static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? JellyfinError else { return false }
        switch error.kind {
        case .transport:
            // 超时 / 连接中断等：典型瞬态。
            return true
        case .noNetwork:
            // 本机没网：等网络就绪就可能成功，是最该重试的一类。
            return true
        case .http(let status):
            return status == 429 || (500..<600).contains(status)
        case .serverUnreachable:
            // 分类里仍有"名字解析失败"（多半是地址打错，重试无意义）与
            // "解析到了但连不上"（服务在重启、端口暂时没起来）两种，
            // 用底层错误码区分，避免把后者也一并放弃。
            return isTransientUnreachable(error.underlying)
        case .badServerURL, .unauthorized, .forbidden,
             .quickConnectDisabled, .quickConnectTimeout, .other:
            return false
        }
    }

    /// 「解析得到但连不上」= 瞬态（值得重试）；「解析不了」= 永久（重试无意义）。
    static func isTransientUnreachable(_ underlying: (any Error)?) -> Bool {
        guard let ns = underlying as NSError?, ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorCannotConnectToHost,   // -1004 服务没起来 / 端口拒绝
             NSURLErrorNetworkConnectionLost: // -1005 中途断连
            return true
        default:
            // -1003 cannotFindHost / -1006 DNS 失败：名字就是错的。
            return false
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

/// Jellyfin 侧会话：档案 + token + 地址决议 + **按地址缓存的 SDK 客户端**。
///
/// 为什么需要它（而不是让 `JellyfinServer` 直接持 client）：
///
/// - `JellyfinClient.Configuration.url` 是 `let`，换地址只能重建客户端；
/// - `JellyfinServer` 是 struct，存不下「地址 → 客户端」的缓存；
/// - 每个请求都要读一次「现在用哪个地址」，所以快路径必须是同步的。
///
/// 客户端按**归一化地址**缓存：同一地址来回切的场景（探活抖动、切走再切回）
/// 不会反复重建 `URLSession`。
final class JellyfinSession: @unchecked Sendable {
    private let lock = NSLock()
    private let baseProfile: ServerProfile
    let token: String?

    /// SDK 客户端的 token 视图（`send` 之外的调用方只关心有没有凭据）。
    var accessToken: String? { token }
    private let sessionConfiguration: URLSessionConfiguration
    private let directory: ServerEndpointDirectory?
    private let fixedClient: JellyfinClient?
    private var clients: [String: JellyfinClient] = [:]

    init(
        profile: ServerProfile,
        token: String?,
        directory: ServerEndpointDirectory?,
        sessionConfiguration: URLSessionConfiguration
    ) {
        self.baseProfile = profile
        self.token = token
        self.directory = directory
        self.sessionConfiguration = sessionConfiguration
        self.fixedClient = nil
    }

    /// 固定单一客户端（测试 / 还没有档案的探活阶段）：地址不参与决议。
    init(profile: ServerProfile, fixedClient: JellyfinClient) {
        self.baseProfile = profile
        self.token = fixedClient.accessToken
        self.directory = nil
        self.sessionConfiguration = .default
        self.fixedClient = fixedClient
    }

    /// 当前生效地址。
    var activeURL: URL { directory?.currentURL ?? baseProfile.baseURL }

    /// 档案的实时视图：`baseURL` 换成当前生效地址，其余字段原样。
    var profile: ServerProfile {
        var updated = baseProfile
        updated.baseURL = activeURL
        return updated
    }

    var client: JellyfinClient { client(for: activeURL) }

    func client(for url: URL) -> JellyfinClient {
        if let fixedClient { return fixedClient }
        return lock.withLock {
            let key = ServerAddress.normalized(url).absoluteString
            if let cached = clients[key] { return cached }
            let created = JellyfinServer.makeClient(
                baseURL: url, token: token, sessionConfiguration: sessionConfiguration)
            clients[key] = created
            return created
        }
    }

    /// 请求前的地址决议（首启 / 网络变化时等一次探活，平时同步读缓存）。
    func resolvedURL() async -> URL {
        guard let directory else { return baseProfile.baseURL }
        return await directory.resolvedURL()
    }

    /// 某条地址上的请求失败：重新探活，返回是否换到了别的地址。
    func failover(from failed: URL) async -> Bool {
        guard let directory else { return false }
        return await directory.reportFailure(of: failed)
    }
}
