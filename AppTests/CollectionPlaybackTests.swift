import CoreModel
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 合集（BoxSet）是**容器**，不是可播放条目。
///
/// 现场（Jellyfin 12.1.0 实测）：`/Items/{合集id}/PlaybackInfo` → **400**、
/// `/Videos/{合集id}/stream` → **400**、`/Items?ids={合集id}&fields=MediaSources`
/// 里 `MediaSources` 为空。而修复前 `resolvePlayableItem` 只特判 `.series`，
/// 于是合集把自己原样送进协商：PlaybackInfo 400 → 回退拼 `/Videos/{合集id}/stream`
/// （`streamURL` 只拼字符串、不抛错）→ **播放器照样弹出来再报错**。
@MainActor
final class CollectionPlaybackTests: XCTestCase {

    private func makeApp(server: StubMediaServer) -> AppModel {
        let app = AppModel()
        app.phase = .ready
        app.server = server
        app.sessionGeneration = 1
        return app
    }

    private func collection(id: String = "box-1") -> MediaItem {
        MediaItem(id: id, name: "合集", kind: .boxSet, childCount: 2)
    }

    private func movie(_ id: String, watched: Bool, year: Int = 2012) -> MediaItem {
        MediaItem(
            id: id, name: id, kind: .movie, year: year,
            playState: MediaItem.PlayState(
                played: watched, percentage: watched ? 1 : 0, positionSeconds: 0))
    }

    private func page(_ items: [MediaItem]) -> MediaItemsPage {
        MediaItemsPage(items: items, startIndex: 0, totalRecordCount: items.count)
    }

    /// 成员里第一个没看过的电影是解析结果。
    func testCollectionResolvesToFirstUnwatchedMember() async throws {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.itemsPageResult = .success(page([
            movie("m-1", watched: true),
            movie("m-2", watched: false),
            movie("m-3", watched: false),
        ]))

        let resolved = try await app.resolvePlayableItem(for: collection(), server: server)

        XCTAssertEqual(resolved?.id, "m-2", "应当跳看过的，取第一个没看过的成员")
    }

    /// 成员全部看过：退回第一个成员（与剧集那条「没有未看的就取第一集」同口径）。
    func testCollectionFallsBackToFirstMemberWhenAllWatched() async throws {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.itemsPageResult = .success(page([
            movie("m-1", watched: true),
            movie("m-2", watched: true),
        ]))

        let resolved = try await app.resolvePlayableItem(for: collection(), server: server)

        XCTAssertEqual(resolved?.id, "m-1")
    }

    /// 成员查询必须是 `recursive: false` 且以合集自身为 parent：
    /// 合集里可以放剧集，递归查询会把季与集一并拉出来。
    func testCollectionMembersAreQueriedNonRecursively() async throws {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.itemsPageResult = .success(page([movie("m-1", watched: false)]))

        _ = try await app.resolvePlayableItem(for: collection(id: "box-9"), server: server)

        let query = try XCTUnwrap(server.lastItemsPageQuery)
        XCTAssertEqual(query.parentID, "box-9", "必须以合集自身为 parent")
        XCTAssertFalse(query.recursive, "合集成员不能递归取——剧集成员会把季/集一起带出来")
        XCTAssertNil(query.kinds, "合集可以混放电影与剧，不能按类型过滤")
        XCTAssertNil(query.searchTerm)
        XCTAssertNil(query.watchState, "挑选在客户端做，服务端不要再过滤掉「看过的」")
    }

    /// 空合集：解析不出可播条目（而不是把合集自身当成可播条目）。
    func testEmptyCollectionResolvesToNil() async throws {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.itemsPageResult = .success(page([]))

        let resolved = try await app.resolvePlayableItem(for: collection(), server: server)

        XCTAssertNil(resolved)
    }

    /// 成员里只有剧集时，回到剧集自己的解析规则（它可能已经有续播进度）。
    func testCollectionWithOnlySeriesResolvesThroughSeriesRule() async throws {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        let series = MediaItem(id: "s-1", name: "剧", kind: .series)
        server.itemsPageResult = .success(page([series]))
        server.episodesResult = .success([
            MediaItem(id: "e-1", name: "已看", kind: .episode, seriesID: "s-1", seasonNumber: 1,
                      episodeNumber: 1,
                      playState: MediaItem.PlayState(played: true, percentage: 1, positionSeconds: 0)),
            MediaItem(id: "e-2", name: "没看", kind: .episode, seriesID: "s-1", seasonNumber: 1,
                      episodeNumber: 2),
        ])

        let resolved = try await app.resolvePlayableItem(for: collection(), server: server)

        XCTAssertEqual(resolved?.id, "e-2", "成员是剧集时，要解析成该剧第一个没看过的常规集")
    }

    /// 服务端出错时**往上抛**（交给 `openPlayback` 的 catch 出错误态），不静默返回合集自身。
    func testCollectionQueryFailurePropagates() async {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.itemsPageResult = .failure(JellyfinError(.transport("请求超时。")))

        do {
            let resolved = try await app.resolvePlayableItem(for: collection(), server: server)
            XCTFail("应当抛错，实际返回 \(String(describing: resolved))")
        } catch {
            XCTAssertTrue(error is JellyfinError)
        }
    }

    /// 解析不出内容时的文案按类型说清楚（合集 / 剧集 / 其它），不能一律说「该剧…」。
    func testNoPlayableContentMessageMatchesItemKind() {
        XCTAssertEqual(
            AppModel.noPlayableContentMessage(for: collection()),
            "这个合集里还没有可播放的内容")
        XCTAssertEqual(
            AppModel.noPlayableContentMessage(for: MediaItem(id: "s", name: "剧", kind: .series)),
            "该剧没有可播放的剧集")
        XCTAssertEqual(
            AppModel.noPlayableContentMessage(for: MediaItem(id: "p", name: "播放列表", kind: .playlist)),
            "这个条目没有可播放的内容")
    }
}
