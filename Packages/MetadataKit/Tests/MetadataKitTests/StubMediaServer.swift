import CoreModel
import Foundation
import JellyfinKit

// 复制自 `AppTests/StubMediaServer.swift` 的思路：只实现用例真正关心的那几条
// （用 `Result` 逐条注入成功 / 失败），其余走最小实现。
//
// 刻意**不加 `@MainActor`**：`MediaServer` 里有同步要求（`profile` /
// `authorizationHeader` / `imageURL` / `streamURL`），主 actor 隔离的成员满足不了。
// 可变配置项由用例单线程写入，`@unchecked Sendable` 是明确的取舍。
final class StubMediaServer: MediaServer, @unchecked Sendable {
    let profile: ServerProfile

    var authorizationHeader = "Stub Client=\"test\""

    // 逐条注入成功 / 失败。
    var userViewsResult: Result<[MediaLibrary], any Error> = .success([])
    var resumeResult: Result<[MediaItem], any Error> = .success([])
    var nextUpResult: Result<[MediaItem], any Error> = .success([])
    var latestResult: Result<[MediaItem], any Error> = .success([])
    var favoriteResult: Result<[MediaItem], any Error> = .success([])
    var itemResult: Result<MediaItem, any Error>?
    var itemsPageResult: Result<MediaItemsPage, any Error>?
    var seasonsResult: Result<[MediaItem], any Error> = .success([])
    var episodesResult: Result<[MediaItem], any Error> = .success([])
    var mediaFileInfoResult: Result<MediaFileInfo?, any Error> = .success(nil)
    var markPlayedResult: Result<MediaItem.PlayState, any Error>?

    /// 记录调用次数：用来断言「装饰器转发了几次、有没有多打请求」。
    ///
    /// ⚠️ 加锁：`loadHome` 那类调用点用 `async let` 并发发请求，裸字典并发改写
    /// 会把结构写坏（实测在 AppTests 那份同名替身上打成 SIGABRT）。
    private let counterLock = NSLock()
    private var _callCounts: [String: Int] = [:]
    var callCounts: [String: Int] {
        counterLock.lock(); defer { counterLock.unlock() }
        return _callCounts
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
            kind: kind)
    }

    // MARK: - 浏览

    func userViews() async throws -> [MediaLibrary] {
        count("userViews"); return try userViewsResult.get()
    }
    func resumeItems() async throws -> [MediaItem] {
        count("resumeItems"); return try resumeResult.get()
    }
    func nextUp() async throws -> [MediaItem] {
        count("nextUp"); return try nextUpResult.get()
    }
    func latestItems(limit: Int) async throws -> [MediaItem] {
        count("latestItems"); return try latestResult.get()
    }
    func favoriteItems(limit: Int) async throws -> [MediaItem] {
        count("favoriteItems"); return try favoriteResult.get()
    }
    /// 刻意弹错：装饰器不该把它当成「必需」的东西而让整条路径失败。
    func randomBackdropItems(limit: Int) async throws -> [MediaItem] {
        count("randomBackdropItems"); return []
    }

    func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        count("markPlayed")
        guard let markPlayedResult else { return .init(played: true, percentage: 1, positionSeconds: 0) }
        return try markPlayedResult.get()
    }
    func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        count("markUnplayed")
        return .init(played: false, percentage: 0, positionSeconds: 0)
    }

    // MARK: - 详情

    func item(_ id: String) async throws -> MediaItem {
        count("item")
        if let itemResult { return try itemResult.get() }
        return MediaItem(id: id, name: id, kind: .movie)
    }
    func chapters(itemID: String) async throws -> [JellyfinChapter] {
        count("chapters"); return []
    }
    func itemsPage(
        parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool,
        startIndex: Int, limit: Int, sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?, searchTerm: String?
    ) async throws -> MediaItemsPage {
        count("itemsPage")
        if let itemsPageResult { return try itemsPageResult.get() }
        return MediaItemsPage(items: [], startIndex: startIndex, totalRecordCount: 0)
    }
    func items(parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool, limit: Int) async throws -> [MediaItem] {
        count("items"); return []
    }
    func seasons(seriesID: String) async throws -> [MediaItem] {
        count("seasons"); return try seasonsResult.get()
    }
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        count("episodes"); return try episodesResult.get()
    }
    func episodes(seriesID: String, startingAt startItemID: String, limit: Int) async throws -> [MediaItem] {
        count("episodesStartingAt"); return try episodesResult.get()
    }
    func similar(itemID: String, limit: Int) async throws -> [MediaItem] {
        count("similar"); return []
    }

    // MARK: - 媒体资源

    func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL {
        URL(string: "http://stub.local:8096/Items/\(itemID)/Images/\(type.rawValue)")!
    }
    func streamURL(itemID: String, mediaSourceID: String?, playSessionID: String?) throws -> String {
        "http://stub.local:8096/Videos/\(itemID)/stream"
    }
    func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] {
        count("mediaSegments"); return []
    }
    func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] {
        count("externalSubtitles"); return []
    }
    func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL {
        count("downloadSubtitle")
        return URL(fileURLWithPath: "/tmp/stub.srt")
    }
    func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? {
        count("mediaFileInfo"); return try mediaFileInfoResult.get()
    }
    func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        count("playbackInfo")
        throw StubError.notConfigured
    }

    // MARK: - 进度上报

    func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {
        count("reportPlaybackStart")
    }
    func reportPlaybackProgress(context: PlaybackSessionContext, positionSeconds: Double, isPaused: Bool) async {
        count("reportPlaybackProgress")
    }
    func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {
        count("reportPlaybackStopped")
    }
}

enum StubError: Error, Equatable {
    case notConfigured
    case boom
}
