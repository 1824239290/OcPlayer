import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import JellyfinKit
@testable import MetadataKit

/// 写穿装饰器：**返回值与错误必须与内层完全一致**（它是纯副作用层）。
struct CachedMediaServerTests {

    private func makeFixture() async throws
        -> (CachedMediaServer, StubMediaServer, MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store = MetadataStore(database: pool)
        let stub = StubMediaServer()
        let tenant = TenantID(profile: stub.profile)
        return (CachedMediaServer(wrapping: stub, store: store, tenant: tenant), stub, store, tenant, dir)
    }

    // MARK: - 条目与 rail 的原子性（CORR-03）

    /// **条目与 rail 必须在同一个事务里写。**
    ///
    /// `CachedMediaServer.record` 的注释一直声称「条目与 rail 必须同一次写」，
    /// 而实现是 `saveItems` + `saveRail` 两次 `await`、**各自开事务** ——
    /// 进程在两次写之间被杀会留下「新 rail + 旧条目」的不一致快照。
    ///
    /// 判据不能只看「都写进去了」（分开写也能都写进去）。这里用 SQLite 触发器
    /// 让 **rail 那次写必然失败**，然后断言**条目也没落盘**：
    /// - 同一事务 → rail 失败把条目一起回滚 → 条目查不到 ✅
    /// - 两个事务 → 条目已经提交，rail 失败只影响自己 → 条目查得到 ❌
    @Test func itemsAndRailAreWrittenInOneTransaction() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        // 让 rail 的写入必然失败。
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rail_write_fails BEFORE INSERT ON rail
                BEGIN SELECT RAISE(ABORT, 'rail write blocked for test'); END
                """)
        }

        stub.resumeResult = .success([makeItem(id: "atomic-1", name: "原子")])
        // `resumeItems()` 会写条目 + rail("resume")；rail 必失败，异常被 record 吞掉。
        _ = try? await server.resumeItems()

        // rail 必然没写进去（触发器拦住）。
        #expect(try await store.rail("resume", tenant: tenant) == nil)

        // 关键断言：条目也必须是**回滚**状态。若实现是两次独立事务，这里会查得到。
        let cached = try await store.items(["atomic-1"], tenant: tenant)
        #expect(
            cached.isEmpty,
            "rail 写失败后条目仍然落盘 —— 说明条目与 rail 不在同一个事务里（CORR-03 回归）")

        // 反向对照：把触发器去掉后两者都能写进去（证明上面的失败确实来自触发器，
        // 而不是别的原因让整条路径都不工作）。
        try await store.database.write { db in
            try db.execute(sql: "DROP TRIGGER rail_write_fails")
        }
        _ = try? await server.resumeItems()
        #expect(try await store.rail("resume", tenant: tenant)?.items.map(\.id) == ["atomic-1"])
        #expect(try await store.items(["atomic-1"], tenant: tenant).map { $0.item.id } == ["atomic-1"])
    }

    /// 对照：**分开写**确实会留下不一致快照（证明上一条用例的判据是有效的）。
    ///
    /// 直接调 `saveItems` 再调必然失败的 `saveRail`，断言条目**留下来了** ——
    /// 这正是旧实现的行为，也是上一条用例要防住的东西。
    @Test func separateWritesWouldLeaveItemsBehind() async throws {
        let (_, _, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rail_write_fails BEFORE INSERT ON rail
                BEGIN SELECT RAISE(ABORT, 'rail write blocked for test'); END
                """)
        }

        let item = makeItem(id: "separate-1", name: "分开写")
        try await store.saveItems([item], tenant: tenant)
        // 第二次写必然失败（触发器），且**不会**回滚第一次 —— 这正是旧实现的形状。
        await #expect(throws: (any Error).self) {
            try await store.saveRail([item], rail: "resume", tenant: tenant)
        }

        // 条目已提交 —— 与 rail 失败无关。这就是旧实现留下的「新条目 + 旧 rail」。
        #expect(try await store.items(["separate-1"], tenant: tenant).map { $0.item.id } == ["separate-1"])
        #expect(try await store.rail("resume", tenant: tenant) == nil)
    }

    /// **服务端说「这个 rail 没有内容」时，必须把磁盘上的旧 rail 清掉。**
    ///
    /// 「空 items + 非 nil rail」是一个**有意义的组合**，不是空操作：
    /// `saveRail` 会写 `RailSnapshot(items: [])` 覆盖上一份。
    /// 而 `MetadataHydrator.home()` 读 rail **没有任何新鲜度门槛** ——
    /// 冷启动 / 离线时会把残留的过期条目当「继续观看」铺上首页。
    ///
    /// 回归背景：`saveItemsAndRail` 第一版写了 `guard !items.isEmpty else { return }`，
    /// 把清空路径一刀切掉。独立审查端到端实测出「服务端返回空之后磁盘仍是旧 rail」。
    @Test func emptyRailResponseClearsStaleRail() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        // 上次成功拉取：rail 里有内容。
        stub.resumeResult = .success([makeItem(id: "stale", name: "过期")])
        _ = try await server.resumeItems()
        #expect(try await store.rail("resume", tenant: tenant)?.items.map(\.id) == ["stale"])

        // 这次服务端说「没有续播」——空 items + 非 nil rail。
        stub.resumeResult = .success([])
        _ = try await server.resumeItems()

        let after = try await store.rail("resume", tenant: tenant)
        #expect(after != nil, "空响应也要写一份空快照（而不是什么都不写）")
        #expect(after?.items.isEmpty == true,
                "过期 rail 残留了 —— 首页会铺出早已看完的条目")
    }

    /// 直接钉 `saveItemsAndRail` 在「空 items + 非 nil rail」下的语义
    /// （不走 `CachedMediaServer`，避免上面的用例只覆盖到一条链路）。
    @Test func saveItemsAndRailWithEmptyItemsStillClearsRail() async throws {
        let (_, _, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        try await store.saveRail([makeItem(id: "old", name: "旧")], rail: "resume", tenant: tenant)
        #expect(try await store.rail("resume", tenant: tenant)?.items.map(\.id) == ["old"])

        try await store.saveItemsAndRail([], rail: "resume", tenant: tenant)
        #expect(try await store.rail("resume", tenant: tenant)?.items.isEmpty == true,
                "空 items 也必须覆盖 rail（否则旧快照永远清不掉）")

        // `rail: nil` + 空 items 才是真正的空操作（不能把什么都写一遍）。
        try await store.saveItemsAndRail([], rail: nil, tenant: tenant)
        #expect(try await store.rail("resume", tenant: tenant)?.items.isEmpty == true)
    }

    // MARK: - 写穿

    @Test func homeRailsArePersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .success([makeItem(id: "r1", name: "续播")])
        stub.nextUpResult = .success([makeItem(id: "n1", name: "下一集", kind: .episode)])
        stub.latestResult = .success([makeItem(id: "l1", name: "最近")])
        stub.userViewsResult = .success([
            MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
        ])

        _ = try await server.resumeItems()
        _ = try await server.nextUp()
        _ = try await server.latestItems(limit: 24)
        _ = try await server.userViews()

        // rail 快照
        #expect(try await store.rail("resume", tenant: tenant)?.items.map(\.id) == ["r1"])
        #expect(try await store.rail("nextUp", tenant: tenant)?.items.map(\.id) == ["n1"])
        #expect(try await store.rail("latest", tenant: tenant)?.items.map(\.id) == ["l1"])
        // 条目也写进了 item 表（详情页靠它离线可用）
        #expect(try await store.item("r1", tenant: tenant)?.item.name == "续播")
        // 库列表
        #expect(try await store.libraries(tenant: tenant).map(\.library.id) == ["lib-1"])
    }

    @Test func itemAndChildrenArePersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemResult = .success(makeItem(id: "series-1", name: "某番", kind: .series, tmdbID: "241535"))
        stub.seasonsResult = .success([makeItem(id: "season-1", name: "第 1 季", kind: .season, seasonNumber: 1)])
        stub.episodesResult = .success([
            makeItem(id: "ep-1", name: "第一集", kind: .episode, seasonNumber: 1, episodeNumber: 1),
        ])

        _ = try await server.item("series-1")
        _ = try await server.seasons(seriesID: "series-1")
        _ = try await server.episodes(seriesID: "series-1", seasonID: "season-1")

        #expect(try await store.item("series-1", tenant: tenant)?.item.tmdbID == "241535")
        #expect(try await store.item("season-1", tenant: tenant)?.item.kind == .season)
        let episode = try await store.item("ep-1", tenant: tenant)
        #expect(episode?.item.episodeNumber == 1)
        #expect(episode?.item.seasonNumber == 1)
    }

    @Test func itemsPagePersistsItemsOnly() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [makeItem(id: "p1", name: "条目一"), makeItem(id: "p2", name: "条目二")],
            startIndex: 0, totalRecordCount: 137))

        let page = try await server.itemsPage(
            parentID: "lib-1", kinds: [.movie], recursive: true,
            startIndex: 0, limit: 60, sort: MediaItemsSort(field: .name, ascending: true),
            watchState: .all, searchTerm: nil)
        #expect(page.totalRecordCount == 137)

        // 页快照不再写盘（没有任何读路径）；页里的条目仍要进 item 表：
        // 否则离线进详情页是空的。
        #expect(try await store.item("p1", tenant: tenant)?.item.name == "条目一")
        #expect(try await store.item("p2", tenant: tenant)?.item.name == "条目二")
    }

    /// `nil` 结果原样透传（「没有媒体源」与「有媒体源」都不落缓存——
    /// mediaFileInfo 的缓存写路径已删，纯透传）。
    @Test func nilMediaFileInfoPassesThrough() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.mediaFileInfoResult = .success(nil)
        let result = try await server.mediaFileInfo(itemID: "e1")
        #expect(result == nil)
    }

    /// 标记已看：服务端返回的 playState 是权威值，直接写回缓存。
    @Test func markPlayedWritesAuthoritativePlayState() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemResult = .success(makeItem(id: "m1", name: "电影",
                                            playState: .init(played: false, percentage: 0, positionSeconds: 0)))
        _ = try await server.item("m1")
        stub.markPlayedResult = .success(.init(played: true, percentage: 1, positionSeconds: 7200))

        let state = try await server.markPlayed(itemID: "m1")
        #expect(state.played)

        let cached = try #require(try await store.item("m1", tenant: tenant))
        #expect(cached.item.playState?.played == true)
        #expect(cached.item.playState?.positionSeconds == 7200)
        // 进度时间戳刷新了，元数据时间戳没动（进度变了不代表简介过期）。
        #expect(cached.progressFetchedAt != nil)
    }

    // MARK: - 返回值 / 错误严格透传

    /// 错误必须原样抛（不吞、不换成缓存）——这是「UI 层才能决定要不要用旧数据」的前提。
    @Test func errorsPropagateUnchanged() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .failure(StubError.boom)
        stub.itemResult = .failure(StubError.boom)
        stub.userViewsResult = .failure(StubError.boom)

        await #expect(throws: StubError.boom) { _ = try await server.resumeItems() }
        await #expect(throws: StubError.boom) { _ = try await server.item("x") }
        await #expect(throws: StubError.boom) { _ = try await server.userViews() }
    }

    /// 失败时**不留半份缓存**：请求失败不该写盘。
    @Test func failedRequestWritesNothing() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .failure(StubError.boom)
        _ = try? await server.resumeItems()
        #expect(try await store.rail("resume", tenant: tenant) == nil)
        #expect(try await store.itemCount() == 0)
    }

    /// 返回值必须与内层**逐个字段一致**（装饰器不能悄悄改数据）。
    @Test func returnedValuesMatchInnerExactly() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let original = makeItem(id: "m1", name: "电影", kind: .movie, year: 2024,
                                playState: .init(played: false, percentage: 0.5, positionSeconds: 3600),
                                tmdbID: "603")
        stub.itemResult = .success(original)
        let returned = try await server.item("m1")
        #expect(returned == original)

        stub.resumeResult = .success([original])
        let rail = try await server.resumeItems()
        #expect(rail == [original])
    }

    /// 不缓存的几条（随机 / 推荐 / 章节 / 播放协商）**一次都不该写盘**，
    /// 且要真的转发到内层（别被装饰器吞掉）。
    @Test func passThroughMethodsForwardWithoutCaching() async throws {
        let (server, stub, store, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        _ = try await server.randomBackdropItems(limit: 8)
        _ = try await server.similar(itemID: "m1", limit: 12)
        _ = try await server.chapters(itemID: "m1")
        _ = try await server.mediaSegments(itemID: "m1")
        _ = try await server.externalSubtitles(itemID: "m1")
        // `playbackInfo` 在 stub 上刻意抛错（一次性 playSessionId 不该被缓存）；
        // 这里要确认的是「错误照样原样抛出来，且装饰器没写盘」，用 try? 取结果。
        let playback = try? await server.playbackInfo(itemID: "m1")
        #expect(playback == nil)

        #expect(stub.callCounts["randomBackdropItems"] == 1)
        #expect(stub.callCounts["similar"] == 1)
        #expect(stub.callCounts["chapters"] == 1)
        #expect(stub.callCounts["mediaSegments"] == 1)
        #expect(stub.callCounts["externalSubtitles"] == 1)
        #expect(stub.callCounts["playbackInfo"] == 1, "错误也要真的打到内层")
        #expect(try await store.itemCount() == 0, "这些方法都不该写盘")
    }

    /// 直通属性/方法不改变语义（图片 / 流地址由上层按当前地址现场拼）。
    @Test func passthroughPropertiesAndURLs() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        #expect(server.profile.id == stub.profile.id)
        #expect(server.authorizationHeader == stub.authorizationHeader)
        let image = try server.imageURL(itemID: "m1", type: .primary, maxWidth: 300, tag: "t")
        #expect(image.absoluteString.contains("/Items/m1/Images/Primary"))
        #expect(try server.streamURL(itemID: "m1", mediaSourceID: nil, playSessionID: nil)
            .contains("/Videos/m1/stream"))
    }

    /// 进度上报三条原样转发（装饰器不该插手播放链路）。
    @Test func playbackReportingForwards() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let context = PlaybackSessionContext(
            itemID: "m1", playSessionID: "sess-1", mediaSourceID: nil,
            deliveryMethod: .directPlay)
        await server.reportPlaybackStart(context: context, positionSeconds: 0)
        await server.reportPlaybackProgress(context: context, positionSeconds: 10, isPaused: false)
        await server.reportPlaybackStopped(context: context, positionSeconds: 20)
        #expect(stub.callCounts["reportPlaybackStart"] == 1)
        #expect(stub.callCounts["reportPlaybackProgress"] == 1)
        #expect(stub.callCounts["reportPlaybackStopped"] == 1)
    }

    /// 租户来自档案：换地址（同一台服务器）时缓存仍然命中同一租户。
    @Test func tenantFollowsProfileNotAddress() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .success([makeItem(id: "r1")])
        _ = try await server.resumeItems()
        // 换地址后的档案（同一 serverID:userID）派生出的租户必须相同。
        var moved = stub.profile
        moved.baseURL = URL(string: "http://100.127.128.96:8096")!
        #expect(TenantID(profile: moved) == tenant)
        #expect(try await store.rail("resume", tenant: TenantID(profile: moved)) != nil)
    }
}
