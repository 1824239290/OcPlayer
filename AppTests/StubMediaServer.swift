import CoreModel
import Foundation
import JellyfinKit

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

    func userViews() async throws -> [MediaLibrary] { try userViewsResult.get() }
    func resumeItems() async throws -> [MediaItem] { try resumeResult.get() }
    func nextUp() async throws -> [MediaItem] { try nextUpResult.get() }
    func latestItems(limit: Int) async throws -> [MediaItem] { try latestResult.get() }
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
        MediaItem(id: id, name: id, kind: .movie)
    }

    func chapters(itemID: String) async throws -> [JellyfinChapter] { [] }
    func seasons(seriesID: String) async throws -> [MediaItem] { [] }
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] { [] }
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
        MediaItemsPage(items: [], startIndex: startIndex, totalRecordCount: 0)
    }

    func items(parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool, limit: Int) async throws -> [MediaItem] { [] }

    // MARK: - 媒体资源

    func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL {
        URL(string: "http://stub.local:8096/Items/\(itemID)/Images/\(type.rawValue)")!
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
