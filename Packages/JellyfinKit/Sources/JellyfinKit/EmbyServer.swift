import CoreModel
import Foundation

/// 一台已登录的 Emby 服务器。
///
/// 与 `JellyfinServer` 实现同一条 `MediaServer` 契约，但走**裸 HTTP + 宽松 DTO**，
/// 不依赖 `jellyfin-sdk-swift`：Emby 的响应值域超出 SDK 的枚举，强解会整包炸
/// （理由见 `MediaServer` 与 `EmbyDTOs` 的文档注释）。
///
/// 路由上的分叉（相对 Jellyfin 的新式路由）：媒体库 `/Users/{id}/Views`、最近添加
/// `/Users/{id}/Items/Latest`、继续观看 `/Users/{id}/Items/Resume`、详情
/// `/Users/{uid}/Items/{id}`、已看标记 `/Users/{uid}/PlayedItems/{id}`。
/// 其余路由两家同形。
public struct EmbyServer: MediaServer {
    public let profile: ServerProfile

    private let session: EmbySession

    /// Emby 用 `Emby` scheme（Jellyfin 是 `MediaBrowser`）。
    public var authorizationHeader: String { session.authorizationHeader }

    init(profile: ServerProfile, session: EmbySession) {
        self.profile = profile
        self.session = session
    }

    /// 按档案恢复会话（多服务器切换 / 启动恢复用）。token 缺失时返回 nil，
    /// 由调用方回落到登录流程。
    public static func resume(
        profile: ServerProfile,
        from store: ServerStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) -> EmbyServer? {
        guard let token = store.token(for: profile) else { return nil }
        return EmbyServer(
            profile: profile,
            session: EmbySession(
                baseURL: profile.baseURL,
                accessToken: token,
                profileID: profile.id,
                sessionConfiguration: sessionConfiguration
            )
        )
    }

    private var userID: String { profile.userID }

    // MARK: - 浏览

    public func userViews() async throws -> [MediaLibrary] {
        // Emby 没有 `/UserViews` 新式路由，走老式 `/Users/{id}/Views`。
        let result = try await session.get(
            "/Users/\(userID)/Views",
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? [])
            .map {
                MediaLibrary(
                    id: $0.id ?? UUID().uuidString,
                    name: $0.name ?? "",
                    collectionType: MediaLibrary.CollectionType($0.collectionType)
                )
            }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }

    public func latestItems(limit: Int = 24) async throws -> [MediaItem] {
        // Emby 没有带 userId query 的新式 `/Items/Latest`，走老式
        // `/Users/{id}/Items/Latest`（实测 Emby 4.10 对前者 404）。
        // 两边返回的都是裸数组（非 QueryResult 信封）。
        var query: [(String, String)] = [
            ("limit", String(limit)),
            ("enableImageTypes", "Primary,Backdrop,Thumb"),
        ]
        if let fields = embySafeFields("PrimaryImageAspectRatio") {
            query.append(("fields", fields))
        }
        let items = try await session.get(
            "/Users/\(userID)/Items/Latest",
            query: query,
            as: [EmbyItemDTO].self
        )
        return items.map(\.domainItem)
    }

    public func favoriteItems(limit: Int = 24) async throws -> [MediaItem] {
        let result = try await session.get(
            "/Items",
            query: [
                ("userId", userID),
                ("limit", String(limit)),
                ("sortBy", "DateCreated"),
                ("sortOrder", "Descending"),
                ("includeItemTypes", "Movie,Series"),
                ("filters", "IsFavorite"),
                ("enableImageTypes", "Primary,Backdrop,Logo"),
                ("recursive", "true"),
            ],
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem)
    }

    public func resumeItems() async throws -> [MediaItem] {
        // Emby 走老式 `/Users/{id}/Items/Resume`（Jellyfin 是 `/UserItems/Resume`）。
        let result = try await session.get(
            "/Users/\(userID)/Items/Resume",
            query: [
                ("limit", "24"),
                ("mediaTypes", "Video"),
                ("enableImageTypes", "Primary,Backdrop,Thumb,Logo"),
            ],
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem)
    }

    public func nextUp() async throws -> [MediaItem] {
        let started = Date()
        let result = try await session.get(
            "/Shows/NextUp",
            query: [
                ("userId", userID),
                ("limit", "24"),
                ("enableImageTypes", "Primary,Backdrop,Thumb,Logo"),
            ],
            as: EmbyQueryResultDTO.self
        )
        let items = (result.items ?? []).map(\.domainItem)
        guard items.isEmpty else { return items }
        // 服务器**已经慢**的时候不扫。扫描是 1 + N 条额外请求，在一台 warm 都要
        // 3–9 秒的公网服务器上只会把首页拖得更死；这一行拿不到内容是可接受的
        // 降级，把整页拖住不是。
        guard Date().timeIntervalSince(started) < Self.nextUpSweepSlowThreshold else {
            return []
        }
        return try await nextUpPerSeriesSweep()
    }

    /// Emby 4.10 对**不带 series 范围**的 Next Up 恒返回空数组，而同一查询限定到
    /// 某部剧时返回正确的那一集。所以这里按「最近看过的剧」逐部问一遍。
    ///
    /// 这是对已经拿到的答案（空）的**尽力而为**补充：扫描自身出任何问题都保留
    /// 原答案，不让整行报错。
    private func nextUpPerSeriesSweep() async throws -> [MediaItem] {
        let started = Date()
        let played = try await session.get(
            "/Items",
            query: [
                ("userId", userID),
                ("includeItemTypes", "Episode"),
                ("filters", "IsPlayed"),
                ("recursive", "true"),
                ("sortBy", "DatePlayed"),
                ("sortOrder", "Descending"),
                ("limit", "100"),
                ("fields", "SeriesId"),
            ],
            as: EmbyQueryResultDTO.self
        )
        // 用数组保序（最近看过的剧在前），同时去重——连看一整季会产生几十条同一部剧。
        var seen = Set<String>()
        var seriesIDs: [String] = []
        for item in played.items ?? [] {
            guard let id = item.seriesId, !id.isEmpty, seen.insert(id).inserted else { continue }
            seriesIDs.append(id)
            if seriesIDs.count >= Self.nextUpSweepSeriesLimit { break }
        }
        guard !seriesIDs.isEmpty else { return [] }

        // 逐剧取回是并发的，**回来的顺序不保证**；但这一行的顺序必须是「最近看过的剧
        // 在前」。所以按 id 收进字典，最后按 seriesIDs 的原顺序还原。
        var bySeries: [String: MediaItem] = [:]
        for batch in stride(from: 0, to: seriesIDs.count, by: Self.nextUpSweepConcurrency) {
            let slice = Array(seriesIDs[batch..<min(batch + Self.nextUpSweepConcurrency, seriesIDs.count)])
            await withTaskGroup(of: (String, MediaItem?).self) { group in
                for id in slice {
                    group.addTask { (id, try? await firstNextUp(seriesID: id)) }
                }
                for await (id, item) in group {
                    if let item { bySeries[id] = item }
                }
            }
            // 预算用尽就收手：已经拿到的照常返回，剩下的留空。不这样收口的话，
            // 25 部剧 × 每部 30s 上限能把这一行拖到几分钟。
            if Date().timeIntervalSince(started) >= Self.nextUpSweepBudget { break }
        }
        return seriesIDs.compactMap { bySeries[$0] }
    }

    /// 扫多少部最近看过的剧，以及同时在飞几条请求（小服务器不要一次打满）。
    private static let nextUpSweepSeriesLimit = 25
    private static let nextUpSweepConcurrency = 5

    /// 逐剧扫描的三层收口。扫描是「无范围 Next Up 返回空」时的补充手段，代价是
    /// 1 + N 条额外请求（N 上限 25），而这一行在首页加载的路径上：
    ///
    /// 1. 无范围那次已经慢过 `nextUpSweepSlowThreshold` → 整轮跳过；
    /// 2. 单条请求 `nextUpSweepRequestTimeout` 封顶（默认 30s 对补充请求太宽）；
    /// 3. 整轮 `nextUpSweepBudget` 预算，超了返回已拿到的部分。
    ///
    /// 最坏情况 ≈ 预算 + 一批 = 9 秒，而不是几分钟。
    private static let nextUpSweepSlowThreshold: TimeInterval = 1.5
    private static let nextUpSweepRequestTimeout: TimeInterval = 5
    private static let nextUpSweepBudget: TimeInterval = 4

    private func firstNextUp(seriesID: String) async throws -> MediaItem? {
        let result = try await session.get(
            "/Shows/NextUp",
            query: [
                ("userId", userID),
                ("seriesId", seriesID),
                ("limit", "1"),
                ("enableImageTypes", "Primary,Backdrop,Thumb,Logo"),
            ],
            timeout: Self.nextUpSweepRequestTimeout,
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).first?.domainItem
    }

    public func randomBackdropItems(limit: Int = 24) async throws -> [MediaItem] {
        let result = try await session.get(
            "/Items",
            query: [
                ("userId", userID),
                ("limit", String(limit)),
                ("recursive", "true"),
                ("includeItemTypes", "Movie,Series"),
                ("sortBy", "Random"),
                ("enableImageTypes", "Primary,Backdrop"),
            ],
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem).filter { $0.backdropImageTag != nil }
    }

    // MARK: - 播放状态标记

    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        // Emby 只有老式 `POST /Users/{uid}/PlayedItems/{id}`（与 Views/Resume 同批旧路由）。
        let data = try await session.postIgnoringBody(
            "/Users/\(userID)/PlayedItems/\(itemID)",
            query: [("userId", userID)]
        )
        return try playState(from: data)
    }

    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        let data = try await session.deleteIgnoringBody(
            "/Users/\(userID)/PlayedItems/\(itemID)",
            query: [("userId", userID)]
        )
        return try playState(from: data)
    }

    /// 标记接口返回服务端最新的播放状态快照；解不出来时退回「已按请求生效」的
    /// 最小快照，而不是把一次成功的写入报成失败。
    private func playState(from data: Data) -> MediaItem.PlayState {
        guard let dto = try? session.decode(EmbyUserDataDTO.self, from: data) else {
            return MediaItem.PlayState(played: false, percentage: 0, positionSeconds: 0)
        }
        return dto.domainPlayState
    }

    // MARK: - 详情

    public func item(_ id: String) async throws -> MediaItem {
        try await detail(id, fields: "People,Genres,Overview,Chapters").domainItem
    }

    public func chapters(itemID: String) async throws -> [JellyfinChapter] {
        let dto = try await detail(itemID, fields: "Chapters")
        return (dto.chapters ?? []).enumerated().map { index, info in
            JellyfinChapter(
                name: info.name ?? "章节 \(index + 1)",
                startSeconds: seconds(fromTicks: info.startPositionTicks) ?? 0
            )
        }
    }

    /// Emby 没有 `/Items/{id}` 新式路由，走老式 `/Users/{uid}/Items/{id}`。
    /// 显式带 `fields`：部分服务器版本默认不返回 People 等扩展字段。
    private func detail(_ itemID: String, fields: String) async throws -> EmbyItemDTO {
        var query: [(String, String)] = [("userId", userID)]
        if let safe = embySafeFields(fields) { query.append(("fields", safe)) }
        return try await session.get(
            "/Users/\(userID)/Items/\(itemID)",
            query: query,
            as: EmbyItemDTO.self
        )
    }

    public func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        searchTerm: String? = nil
    ) async throws -> MediaItemsPage {
        let pageSize = max(limit, 1)
        let pageStart = max(startIndex, 0)
        let (sortKeys, sortOrders) = sort.map { $0.rawKeysAndOrders() } ?? (["SortName"], ["Ascending"])

        var query: [(String, String)] = [
            ("userId", userID),
            ("startIndex", String(pageStart)),
            ("limit", String(pageSize)),
            ("recursive", recursive ? "true" : "false"),
            ("sortBy", sortKeys.joined(separator: ",")),
            ("sortOrder", sortOrders.joined(separator: ",")),
            ("enableImageTypes", "Primary,Backdrop,Logo"),
            ("enableTotalRecordCount", "true"),
        ]
        if let searchTerm {
            let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { query.append(("searchTerm", trimmed)) }
        }
        if let parentID { query.append(("parentId", parentID)) }
        if let kinds {
            let wire = kinds.compactMap(Self.wireKind).map(\.self)
            if !wire.isEmpty { query.append(("includeItemTypes", wire.joined(separator: ","))) }
        }
        switch watchState {
        case .watched: query.append(("filters", "IsPlayed"))
        case .unwatched: query.append(("filters", "IsUnplayed"))
        case .all, nil: break
        }

        let result = try await session.get("/Items", query: query, as: EmbyQueryResultDTO.self)
        return MediaItemsPage(
            items: (result.items ?? []).map(\.domainItem),
            startIndex: pageStart,
            totalRecordCount: result.totalRecordCount
        )
    }

    /// 域模型 kind → 服务端 `Type` 串。没有 wire 值的（folder / other）返回 nil。
    private static func wireKind(_ kind: MediaItem.Kind) -> String? {
        switch kind {
        case .movie: "Movie"
        case .series: "Series"
        case .season: "Season"
        case .episode: "Episode"
        case .boxSet: "BoxSet"
        case .musicAlbum: "MusicAlbum"
        case .musicArtist: "MusicArtist"
        case .audio: "Audio"
        case .book: "Book"
        case .photo: "Photo"
        case .playlist: "Playlist"
        case .folder, .other: nil
        }
    }

    public func items(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        limit: Int
    ) async throws -> [MediaItem] {
        let pageSize = max(limit, 1)
        var startIndex = 0
        var loaded: [MediaItem] = []
        // 硬上限：totalRecordCount 异常时防无限翻页（与 Jellyfin 侧同判据）。
        let hardLimit = 10_000

        while loaded.count < hardLimit {
            let page = try await itemsPage(
                parentID: parentID,
                kinds: kinds,
                recursive: recursive,
                startIndex: startIndex,
                limit: pageSize,
                sort: nil,
                watchState: nil
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

    public func seasons(seriesID: String) async throws -> [MediaItem] {
        let result = try await session.get(
            "/Shows/\(seriesID)/Seasons",
            query: [("userId", userID)],
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem)
    }

    public func episodes(seriesID: String, seasonID: String? = nil) async throws -> [MediaItem] {
        let result = try await session.get(
            "/Shows/\(seriesID)/Episodes",
            query: episodesQuery(seasonID: seasonID),
            as: EmbyQueryResultDTO.self
        )
        let episodes = (result.items ?? []).map(\.domainItem)
        return episodes.sorted {
            let lhs = ($0.seasonNumber ?? Int.max, $0.episodeNumber ?? Int.max, $0.id)
            let rhs = ($1.seasonNumber ?? Int.max, $1.episodeNumber ?? Int.max, $1.id)
            return lhs < rhs
        }
    }

    public func episodes(
        seriesID: String,
        startingAt startItemID: String,
        limit: Int
    ) async throws -> [MediaItem] {
        // 返回值保持**服务端顺序**，不本地重排：`startItemId` 的语义是「在服务端
        // 那份顺序里跳到这一条」，按 (季号, 集号) 重排会把夹在窗口里的第 0 季
        // 特典挪到当前集前面，"往后取一条"就取错了。
        var query = episodesQuery(seasonID: nil)
        query.append(("startItemId", startItemID))
        query.append(("limit", String(limit)))
        let result = try await session.get(
            "/Shows/\(seriesID)/Episodes",
            query: query,
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem)
    }

    private func episodesQuery(seasonID: String?) -> [(String, String)] {
        var query: [(String, String)] = [
            ("userId", userID),
            ("enableImages", "true"),
            ("enableImageTypes", "Primary,Thumb,Logo"),
            ("enableUserData", "true"),
            ("sortBy", "IndexNumber"),
        ]
        if let seasonID { query.append(("seasonId", seasonID)) }
        return query
    }

    public func similar(itemID: String, limit: Int = 12) async throws -> [MediaItem] {
        let result = try await session.get(
            "/Items/\(itemID)/Similar",
            query: [("userId", userID), ("limit", String(limit))],
            as: EmbyQueryResultDTO.self
        )
        return (result.items ?? []).map(\.domainItem)
    }

    // MARK: - 媒体资源

    public func imageURL(itemID: String, type: ItemImageType = .primary,
                         maxWidth: Int? = nil, tag: String? = nil) throws -> URL {
        var query: [(String, String)] = []
        if let maxWidth { query.append(("maxWidth", String(maxWidth))) }
        if let tag { query.append(("tag", tag)) }
        return try session.absoluteURL(path: "/Items/\(itemID)/Images/\(type.rawValue)", query: query)
    }

    public func streamURL(
        itemID: String,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil
    ) throws -> String {
        var query: [(String, String)] = [("Static", "true")]
        if let mediaSourceID { query.append(("mediaSourceId", mediaSourceID)) }
        if let playSessionID { query.append(("playSessionId", playSessionID)) }
        return try session.absoluteURL(path: "/Videos/\(itemID)/stream", query: query).absoluteString
    }

    /// Emby 没有 `/MediaSegments` 接口（那是 Jellyfin 插件生态提供的），
    /// 但它把片头 / 片尾标成了**章节 marker**。这里读章节、把 marker 翻译成与
    /// Jellyfin 侧同形的 segment，比按章节名猜要准得多。
    public func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] {
        let dto = try await detail(itemID, fields: "Chapters")
        let chapters = dto.chapters ?? []
        guard !chapters.isEmpty else { return [] }

        var chapterStarts: [Int] = []
        var introStart: Int?
        var introEnd: Int?
        var creditsStart: Int?
        for chapter in chapters {
            guard let ticks = chapter.startPositionTicks else { continue }
            chapterStarts.append(ticks)
            switch chapter.markerType {
            case .introStart: introStart = introStart ?? ticks
            case .introEnd: introEnd = introEnd ?? ticks
            case .creditsStart: creditsStart = creditsStart ?? ticks
            case .chapter, .unknown, nil: break
            }
        }

        // 很多集只有起始 marker 没有结束 marker：下一个章节的起点就是片头交接给
        // 正片的位置，用它顶替。后面什么都没有的章节保持无界，不猜长度。
        if introStart != nil, introEnd == nil {
            let start = introStart ?? 0
            introEnd = chapterStarts.filter { $0 > start }.min()
        }

        var segments: [JellyfinMediaSegment] = []
        if let start = introStart, let end = introEnd, end > start {
            segments.append(JellyfinMediaSegment(
                id: "emby-intro-\(itemID)",
                itemID: itemID,
                kind: .intro,
                startSeconds: Double(start) / 10_000_000,
                endSeconds: Double(end) / 10_000_000
            ))
        }
        // 片尾没有结束 marker，一直跑到条目结束。
        if let start = creditsStart, let runtime = dto.runTimeTicks, runtime > start {
            segments.append(JellyfinMediaSegment(
                id: "emby-credits-\(itemID)",
                itemID: itemID,
                kind: .outro,
                startSeconds: Double(start) / 10_000_000,
                endSeconds: Double(runtime) / 10_000_000
            ))
        }
        return segments
    }

    public func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] {
        let source = try await firstMediaSource(itemID: itemID)
        return (source?.mediaStreams ?? []).compactMap {
            $0.domainSubtitle(itemID: itemID, mediaSourceID: source?.id)
        }
    }

    public func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL {
        let data = try await session.data(subtitle.remotePath, method: "GET")
        let directory = URL.applicationSupportDirectory
            .appending(path: "OcPlayer/Subtitles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeID = subtitle.id
            .replacingOccurrences(of: "#", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let safeExt = subtitle.fileExtension
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "..", with: "")
        let url = directory.appending(path: "\(safeID).\(safeExt)")
        try data.write(to: url, options: .atomic)
        return url
    }

    public func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? {
        // 与 externalSubtitles 走同一条 `GET /Items` 路由：显式带 MediaSources
        // field 才拿得到流信息，且**不建播放会话**。
        let result = try await session.get(
            "/Items",
            query: [("userId", userID), ("fields", "MediaSources"), ("ids", itemID)],
            as: EmbyQueryResultDTO.self
        )
        let sources = result.items?.first?.mediaSources ?? []
        guard let index = MediaSourceSelection.preferredIndex(
            count: sources.count,
            supportsDirectPlay: { sources[$0].supportsDirectPlay == true },
            supportsDirectStream: { sources[$0].supportsDirectStream == true }
        ) else { return nil }
        return sources[index].domainFileInfo(sourceCount: sources.count)
    }

    private func firstMediaSource(itemID: String) async throws -> EmbyMediaSourceDTO? {
        let result = try await session.get(
            "/Items",
            query: [("userId", userID), ("fields", "MediaSources"), ("ids", itemID)],
            as: EmbyQueryResultDTO.self
        )
        return result.items?.first?.mediaSources?.first
    }

    public func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        let response = try await session.post(
            "/Items/\(itemID)/PlaybackInfo",
            query: [("userId", userID)],
            body: EmbyPlaybackInfoBody(userID: userID),
            as: EmbyPlaybackInfoDTO.self
        )
        let sources = (response.mediaSources ?? []).map(\.domainSource)
        return PlaybackInfo(playSessionID: response.playSessionId, mediaSources: sources)
    }

    // MARK: - 进度上报

    /// 上报 body 的会话 id：协商过用协商值；没协商过则合成。
    ///
    /// Emby 的 `/Sessions/Playing` 与 `/Sessions/Playing/Progress` 在 body 缺
    /// `PlaySessionId` 时**必拒 400**（`Value cannot be null. (Parameter 'key')`，
    /// 实测 Emby 4.9.5），而回退直连路径（PlaybackInfo 失败 → 裸 URL 播放）拿不到
    /// 协商会话 —— 以前在这条路径上上报 100% 失败，续播位置全部丢失。
    /// 按 `itemId` 合成**确定性** id，保证同一片源的 start / progress / stopped
    /// 三段落在服务端同一会话行，而不是三条孤儿会话。
    func resolvedPlaySessionID(_ context: PlaybackSessionContext) -> String? {
        context.playSessionID ?? "ocplayer-\(context.itemID)"
    }

    public func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {
        let sessionID = resolvedPlaySessionID(context)
        let body = EmbyPlaybackStateBody(
            canSeek: true,
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playMethod: context.deliveryMethod.wireValue,
            playSessionID: sessionID,
            positionTicks: Self.ticks(positionSeconds),
            sessionID: sessionID,
            isPaused: nil
        )
        await report(path: "/Sessions/Playing", body: body, what: "PlaybackStart item=\(context.itemID)")
    }

    public func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        let sessionID = resolvedPlaySessionID(context)
        let body = EmbyPlaybackStateBody(
            canSeek: true,
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playMethod: context.deliveryMethod.wireValue,
            playSessionID: sessionID,
            positionTicks: Self.ticks(positionSeconds),
            sessionID: sessionID,
            isPaused: isPaused
        )
        await report(path: "/Sessions/Playing/Progress", body: body, what: "PlaybackProgress item=\(context.itemID)")
    }

    public func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {
        let body = EmbyPlaybackStopBody(
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playSessionID: resolvedPlaySessionID(context),
            positionTicks: Self.ticks(positionSeconds)
        )
        await report(path: "/Sessions/Playing/Stopped", body: body, what: "PlaybackStopped item=\(context.itemID)")
    }

    /// 上报是尽力而为：失败不影响播放（本地文件 / 离线时静默跳过），只留一条 warning。
    ///
    /// 刻意**不解析响应体**：这几个端点有的回 204 无 body，去解一个空 body 会把
    /// 一次成功的上报报成失败。
    private func report(path: String, body: any Encodable, what: String) async {
        do {
            _ = try await session.requestData(path, method: "POST", body: body)
        } catch {
            NetworkLog.reportFailed(what, error: error)
        }
    }

    /// 秒 → Jellyfin/Emby tick（1 tick = 100 ns）。
    static func ticks(_ seconds: Double) -> Int {
        Int(seconds * 10_000_000)
    }
}
