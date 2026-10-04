import CoreModel
import Foundation
import JellyfinKit
import Testing

// `MediaFileInfo` 的逐字段 init 是 JellyfinKit 包内可见（只有服务端映射层该造它），
// 测试要手工构一个就得走 @testable。
@testable import JellyfinKit
@testable import MetadataKit

/// 库列表 / 首页 rail / 库页 / 媒体信息 / 淘汰。
struct MetadataSnapshotTests {

    private func makeStore() async throws -> (MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        return (MetadataStore(database: pool), TenantID(rawValue: "srv:user"), dir)
    }

    // MARK: - 库列表

    @Test func librariesRoundTripInOrder() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let libraries = [
            MediaLibrary(id: "lib-a", name: "电视剧", collectionType: .tvshows, primaryImageTag: "t1"),
            MediaLibrary(id: "lib-b", name: "电影", collectionType: .movies),
        ]
        try await store.saveLibraries(libraries, tenant: tenant)
        let read = try await store.libraries(tenant: tenant)
        #expect(read.map(\.library.id) == ["lib-a", "lib-b"])
        #expect(read.map(\.library.name) == ["电视剧", "电影"])
        #expect(read[0].library.collectionType == .tvshows)
        #expect(read[0].library.primaryImageTag == "t1")
    }

    /// 库列表是「一份完整清单」：服务端删掉的库不能永远留在侧栏里。
    @Test func savingLibrariesReplacesPreviousSet() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        try await store.saveLibraries([
            MediaLibrary(id: "a", name: "A", collectionType: .movies),
            MediaLibrary(id: "b", name: "B", collectionType: .movies),
        ], tenant: tenant)
        try await store.saveLibraries([
            MediaLibrary(id: "b", name: "B", collectionType: .movies),
        ], tenant: tenant)
        let read = try await store.libraries(tenant: tenant)
        #expect(read.map(\.library.id) == ["b"])
    }

    // MARK: - rail

    @Test func railRoundTripsSelfContainedSnapshot() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let items = [makeItem(id: "r1", name: "第一部"), makeItem(id: "r2", name: "第二部")]
        try await store.saveRail(items, rail: "resume", tenant: tenant)
        let cached = try #require(try await store.rail("resume", tenant: tenant))
        #expect(cached.items.map(\.id) == ["r1", "r2"])
        // 自包含：**不查 item 表**也能拿到完整条目（这正是存快照而不是 id 列表的理由）。
        #expect(cached.items[0].name == "第一部")
        #expect(try await store.item("r1", tenant: tenant) == nil)
    }

    /// 条目被淘汰后 rail 仍完整（不会被删成「洞」）。
    @Test func railSurvivesItemEviction() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "x1"), makeItem(id: "x2")], tenant: tenant)
        try await store.saveRail([makeItem(id: "x1", name: "留住的")], rail: "resume", tenant: tenant)

        try await store.evictItems(keepingAtMost: 0)

        #expect(try await store.item("x1", tenant: tenant) == nil, "item 已被淘汰")
        let rail = try #require(try await store.rail("resume", tenant: tenant))
        #expect(rail.items.count == 1, "rail 是自包含快照，不该被淘汰波及")
        #expect(rail.items[0].name == "留住的")
    }

    /// 同名 rail 覆写而不是堆积。
    @Test func railOverwritesSameName() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        try await store.saveRail([makeItem(id: "old")], rail: "resume", tenant: tenant)
        try await store.saveRail([makeItem(id: "new")], rail: "resume", tenant: tenant)
        let cached = try #require(try await store.rail("resume", tenant: tenant))
        #expect(cached.items.map(\.id) == ["new"])
    }

    // MARK: - page

    @Test func pageRoundTripsWithTotalCount() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let key = PageKey(parentID: "lib-1", kinds: [.movie], sort: MediaItemsSort(field: .name, ascending: true),
                          watchState: .unwatched, searchTerm: nil, startIndex: 0, limit: 60)
        try await store.savePage(
            MediaItemsPage(items: [makeItem(id: "p1"), makeItem(id: "p2")],
                           startIndex: 0, totalRecordCount: 137),
            key: key, tenant: tenant)

        let cached = try #require(try await store.page(key, tenant: tenant))
        #expect(cached.items.map(\.id) == ["p1", "p2"])
        #expect(cached.totalRecordCount == 137)
    }

    /// 分页窗口是不同的格：第 2 页不会覆盖第 1 页。
    @Test func pageKeySeparatesWindows() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        func key(_ start: Int) -> PageKey {
            PageKey(parentID: "lib-1", kinds: [.movie], sort: nil, watchState: nil,
                    searchTerm: nil, startIndex: start, limit: 60)
        }
        try await store.savePage(
            MediaItemsPage(items: [makeItem(id: "first")], startIndex: 0, totalRecordCount: 2),
            key: key(0), tenant: tenant)
        try await store.savePage(
            MediaItemsPage(items: [makeItem(id: "second")], startIndex: 1, totalRecordCount: 2),
            key: key(1), tenant: tenant)

        let page0 = try #require(try await store.page(key(0), tenant: tenant))
        let page1 = try #require(try await store.page(key(1), tenant: tenant))
        #expect(page0.items.map(\.id) == ["first"])
        #expect(page1.items.map(\.id) == ["second"])
    }

    /// 搜索词 / 排序 / 筛选各占不同的格——否则「浏览页」与「搜索页」会互相覆盖，
    /// 或者换排序后拿到旧顺序的错序数据。
    @Test func pageKeySeparatesSearchSortAndWatchState() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let browsing = PageKey(parentID: "lib", kinds: [.movie], sort: nil, watchState: nil,
                               searchTerm: nil, startIndex: 0, limit: 60)
        let searching = PageKey(parentID: "lib", kinds: [.movie], sort: nil, watchState: nil,
                                searchTerm: "败犬", startIndex: 0, limit: 60)
        let byYear = PageKey(parentID: "lib", kinds: [.movie],
                             sort: MediaItemsSort(field: .year, ascending: false),
                             watchState: nil, searchTerm: nil, startIndex: 0, limit: 60)
        let unwatched = PageKey(parentID: "lib", kinds: [.movie], sort: nil,
                                watchState: .unwatched, searchTerm: nil, startIndex: 0, limit: 60)

        try await store.savePage(MediaItemsPage(items: [makeItem(id: "browse")], startIndex: 0, totalRecordCount: 1),
                                 key: browsing, tenant: tenant)
        try await store.savePage(MediaItemsPage(items: [makeItem(id: "search")], startIndex: 0, totalRecordCount: 1),
                                 key: searching, tenant: tenant)

        #expect(try await store.page(browsing, tenant: tenant)?.items.map(\.id) == ["browse"])
        #expect(try await store.page(searching, tenant: tenant)?.items.map(\.id) == ["search"])
        // 没缓存过的键返回 nil，不会误命中隔壁格。
        #expect(try await store.page(byYear, tenant: tenant) == nil)
        #expect(try await store.page(unwatched, tenant: tenant) == nil)
    }

    /// kinds 的传参顺序不该影响命中（同一份查询换顺序要复用同一格）。
    @Test func pageKeyIsOrderInsensitiveForKinds() {
        let a = PageKey(parentID: "lib", kinds: [.movie, .series], sort: nil, watchState: nil,
                        searchTerm: nil, startIndex: 0, limit: 60)
        let b = PageKey(parentID: "lib", kinds: [.series, .movie], sort: nil, watchState: nil,
                        searchTerm: nil, startIndex: 0, limit: 60)
        #expect(a == b)
    }

    // MARK: - 媒体信息

    @Test func mediaFileInfoRoundTrips() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let info = MediaFileInfo(
            video: .init(codec: "hevc", width: 3840, height: 2080, bitrate: 24_500_000,
                         frameRate: 23.976, bitDepth: 10, colorPrimaries: "bt2020",
                         colorTransfer: "pq", colorSpace: "bt2020nc", colorRange: "tv",
                         videoRangeType: "DOVI", profile: "Main 10", isInterlaced: false),
            audioTracks: [.init(codec: "eac3", channels: 6, channelLayout: "5.1", sampleRate: 48000,
                                bitrate: 448_000, language: "jpn", title: "日语", isDefault: true)],
            subtitleTracks: [.init(codec: "ass", language: "chi", title: "简体", isDefault: true,
                                   isForced: false, isExternal: false)],
            container: "mkv", sizeBytes: 12_345_678, durationSeconds: 6900,
            fileName: "ep01.mkv", sourceCount: 1)
        try await store.saveMediaFileInfo(info, itemID: "e1", tenant: tenant)
        let cached = try #require(try await store.mediaFileInfo(itemID: "e1", tenant: tenant))
        #expect(cached.info == info, "媒体信息全字段 round-trip")
    }

    // MARK: - 淘汰

    @Test func evictionKeepsNewestAndReportsCount() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 依次写入 5 条，时间递增 → 最旧的应是 first。
        for (offset, id) in ["first", "second", "third", "fourth", "fifth"].enumerated() {
            try await store.saveItems([makeItem(id: id, name: id)], tenant: tenant,
                                      now: base.addingTimeInterval(TimeInterval(offset)))
        }
        let removed = try await store.evictItems(keepingAtMost: 3)
        #expect(removed == 2)
        #expect(try await store.itemCount() == 3)
        // 最旧的两条先走。
        #expect(try await store.item("first", tenant: tenant) == nil)
        #expect(try await store.item("second", tenant: tenant) == nil)
        #expect(try await store.item("fifth", tenant: tenant) != nil)
    }

    @Test func evictionIsNoOpUnderLimit() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "a"), makeItem(id: "b")], tenant: tenant)
        #expect(try await store.evictItems(keepingAtMost: 10) == 0)
        #expect(try await store.itemCount() == 2)
    }

    // MARK: - 清空

    @Test func clearAllWipesEveryTable() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "i1")], tenant: tenant)
        try await store.saveLibraries([MediaLibrary(id: "l1", name: "L", collectionType: .movies)], tenant: tenant)
        try await store.saveRail([makeItem(id: "i1")], rail: "resume", tenant: tenant)
        try await store.savePage(
            MediaItemsPage(items: [makeItem(id: "i1")], startIndex: 0, totalRecordCount: 1),
            key: PageKey(parentID: "l1", kinds: nil, sort: nil, watchState: nil,
                         searchTerm: nil, startIndex: 0, limit: 60),
            tenant: tenant)

        try await store.clearAll()

        #expect(try await store.itemCount() == 0)
        #expect(try await store.libraries(tenant: tenant).isEmpty)
        #expect(try await store.rail("resume", tenant: tenant) == nil)
        #expect(try await store.hasContent(for: tenant) == false)
    }
}
