import CoreModel
import Foundation
import JellyfinKit

/// 一次 `itemsPage` 调用的入参快照（替身用来让用例断言调用形态）。
struct ItemsPageQuery: Sendable, Equatable {
    var parentID: String?
    var kinds: [MediaItem.Kind]?
    var recursive: Bool
    var startIndex: Int
    var limit: Int
    var sort: MediaItemsSort?
    var watchState: MediaItemsWatchState?
    var searchTerm: String?
}

/// `MediaServer` 的测试替身。
///
/// 只实现用例真正关心的那几条（用 `Result` 逐条注入成功 / 失败），其余走空实现。
/// 存在的理由：`MediaServer` 有 28 条要求，用例往往只在意其中两三条，而首页三条
/// rail 的**独立成败**恰恰需要能逐条注入失败。
///
/// 刻意**不加 `@MainActor`**：`MediaServer` 里有同步要求（`profile` /
/// `authorizationHeader` / `imageURL` / `streamURL`），主 actor 隔离的成员满足不了
/// 它们。可变配置项由用例单线程写入，`@unchecked Sendable` 是明确的取舍。
final class StubMediaServer: MediaServer, @unchecked Sendable {
    let profile: ServerProfile

    var authorizationHeader = "Stub Client=\"test\""

    // 首页三条 rail + 媒体库：可逐条注入失败。
    var userViewsResult: Result<[MediaLibrary], any Error> = .success([])
    var resumeResult: Result<[MediaItem], any Error> = .success([])
    var nextUpResult: Result<[MediaItem], any Error> = .success([])
    var latestResult: Result<[MediaItem], any Error> = .success([])
    /// 详情 / 季 / 集：可注入失败。nil = 用默认空结果。
    var itemResult: Result<MediaItem, any Error>?
    var seasonsResult: Result<[MediaItem], any Error> = .success([])
    var episodesResult: Result<[MediaItem], any Error> = .success([])
    /// 库页 / 合集成员查询：nil = 空页。用例据此注入成员列表。
    var itemsPageResult: Result<MediaItemsPage, any Error>?
    /// 按 `parentID` 分派的页（优先于 `itemsPageResult`）。
    ///
    /// 存在的理由：有用例必须区分「**列合集**」与「**取某个合集的成员**」两类请求
    /// （库卡封面要往下钻一层），一律返回同一页就无法表达那种拓扑。
    /// 键为 nil 的条目对应「不带 parentID」的查询。
    var itemsPageByParent: [String?: MediaItemsPage] = [:]
    /// 最后一次 `itemsPage` 的入参（用例据此断言 `recursive` / `parentID` 这类
    /// **调用形态**——合集成员必须 `recursive: false`，这是本替身记它的唯一理由）。
    private(set) var lastItemsPageQuery: ItemsPageQuery?

    /// 调用计数：用来断言「读缓存不该顺带打网络」。
    ///
    /// ⚠️ **必须加锁**。`loadHome` 用 `async let` 并发拉三条 rail，三个 `count()`
    /// 会同时打进来；裸 `[String: Int]` 并发改写在实测中直接把测试宿主打成
    /// `doesNotRecognizeSelector`（Dictionary 结构被写坏，SIGABRT），表现为
    /// 「用例 0.000 秒失败 + xcodebuild 反复重启宿主」。
    ///
    /// 本类其余可变配置项仍是「用例单线程写入」的约定（`@unchecked Sendable` 的
    /// 既有取舍）；只有这个计数器要跨并发任务，所以单独保护。
    private let counterLock = NSLock()
    private var _callCounts: [String: Int] = [:]
    var callCounts: [String: Int] {
        counterLock.lock(); defer { counterLock.unlock() }
        return _callCounts
    }
    func callCount(_ name: String) -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _callCounts[name] ?? 0
    }
    private func count(_ name: String) {
        counterLock.lock(); defer { counterLock.unlock() }
        _callCounts[name, default: 0] += 1
    }

    init(profileID: String = "srv:user", kind: ServerKind = .jellyfin) {
        profile = ServerProfile(
            id: profileID,
            serverName: "stub",
            baseURL: URL(string: "http://stub.local:8096")!,
            userID: profileID.split(separator: ":").last.map(String.init) ?? profileID,
            kind: kind
        )
    }

    // MARK: - 浏览

    func userViews() async throws -> [MediaLibrary] { count("userViews"); return try userViewsResult.get() }
    func resumeItems() async throws -> [MediaItem] { count("resumeItems"); return try resumeResult.get() }
    func nextUp() async throws -> [MediaItem] { count("nextUp"); return try nextUpResult.get() }
    func latestItems(limit: Int) async throws -> [MediaItem] { count("latestItems"); return try latestResult.get() }
    func favoriteItems(limit: Int) async throws -> [MediaItem] { [] }
    func randomBackdropItems(limit: Int) async throws -> [MediaItem] { [] }

    func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        MediaItem.PlayState(played: true, percentage: 1, positionSeconds: 0)
    }

    func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        MediaItem.PlayState(played: false, percentage: 0, positionSeconds: 0)
    }

    // MARK: - 详情

    func item(_ id: String) async throws -> MediaItem {
        count("item")
        if let itemResult { return try itemResult.get() }
        return MediaItem(id: id, name: id, kind: .movie)
    }

    func chapters(itemID: String) async throws -> [JellyfinChapter] { [] }
    func seasons(seriesID: String) async throws -> [MediaItem] {
        count("seasons")
        return try seasonsResult.get()
    }
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        count("episodes")
        return try episodesResult.get()
    }
    func episodes(seriesID: String, startingAt startItemID: String, limit: Int) async throws -> [MediaItem] { [] }
    func similar(itemID: String, limit: Int) async throws -> [MediaItem] { [] }

    func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        searchTerm: String?
    ) async throws -> MediaItemsPage {
        count("itemsPage")
        lastItemsPageQuery = ItemsPageQuery(
            parentID: parentID, kinds: kinds, recursive: recursive, startIndex: startIndex,
            limit: limit, sort: sort, watchState: watchState, searchTerm: searchTerm)
        if let routed = itemsPageByParent[parentID] { return routed }
        if let itemsPageResult { return try itemsPageResult.get() }
        return MediaItemsPage(items: [], startIndex: startIndex, totalRecordCount: 0)
    }

    func items(parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool, limit: Int) async throws -> [MediaItem] { [] }

    // MARK: - 媒体资源

    func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL {
        // 与真实实现同形：`tag` 进 query（`MediaItem.imageTarget` 会断言它在 URL 里，
        // 那条规则是「图换了 URL 就变 → 磁盘缓存自然失效」的事实依据）。
        var components = URLComponents(string: "http://stub.local:8096/Items/\(itemID)/Images/\(type.rawValue)")!
        var query: [URLQueryItem] = []
        if let maxWidth { query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    func streamURL(itemID: String, mediaSourceID: String?, playSessionID: String?) throws -> String {
        "http://stub.local:8096/Videos/\(itemID)/stream"
    }

    func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] { [] }
    func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] { [] }
    func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? { nil }

    /// `PlaybackInfo` 的构造是包内收口的（只有包自己该造它），替身不越权去造一个。
    /// 需要开播协商的用例请另配一个替身，别把这条改成返回假值——那会让「协商失败
    /// 走回退直连」这条真实路径在测试里消失。
    func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        throw JellyfinError(.other("StubMediaServer 不提供开播协商"))
    }

    // MARK: - 进度上报

    func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {}
    func reportPlaybackProgress(context: PlaybackSessionContext, positionSeconds: Double, isPaused: Bool) async {}
    func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {}
}
