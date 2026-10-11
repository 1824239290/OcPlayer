import CoreModel
import Foundation
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 详情页**点击预取**：`openDetail` 在 push 的同时发 item/季/集请求并落快照，
/// 进页 `load()` 读到 TTL 内的新快照后零请求秒出（TTL 语义见 `DetailSnapshotTTLTests`）。
///
/// 这里钉四件事：请求形态与并行度（series 一轮拉齐 item+季+集）、in-flight 去重
/// （连点不重发）、按 kind 分流（电影只发 item、合集带成员页）、快照足够新时
/// 预取直接免了。预取失败静默（进页 load() 兜底）属于网络层行为，不在此覆盖。
@MainActor
final class DetailPrefetchTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailPrefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DetailPrefetch-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    /// 与 `DetailLoadCancellationTests.makeApp` 同构。
    private func makeApp() async throws -> (AppModel, StubMediaServer) {
        let app = AppModel(
            tmdb: TMDbCoordinator(defaults: try XCTUnwrap(defaults), sessionConfiguration: nil),
            preferences: try XCTUnwrap(defaults))
        app.metadata.setup(directory: directory)
        let ready = await app.metadata.waitUntilReady()
        XCTAssertTrue(ready, "临时目录建库应成功")
        let stub = StubMediaServer()
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        return (app, stub)
    }

    private func series(id: String = "s-1") -> MediaItem {
        MediaItem(id: id, name: "学生会也存活！", kind: .series)
    }

    private func season(id: String = "se-1", number: Int = 1) -> MediaItem {
        MediaItem(id: id, name: "第 \(number) 季", kind: .season,
                  seriesID: "s-1", seasonNumber: number)
    }

    private func episode(id: String, number: Int) -> MediaItem {
        MediaItem(id: id, name: "第 \(number) 集", kind: .episode,
                  seriesID: "s-1", seasonNumber: 1, episodeNumber: number)
    }

    /// 等一条预取落地（任务完成后从 `detailPrefetchTasks` 撤槽）。
    private func awaitPrefetch(_ app: AppModel, id: String) async {
        await app.detailPrefetchTasks[id]?.value
        await Task.yield()
    }

    /// series：一轮并行拉齐 item + 季 + 首选季的集，落成进页可直接 TTL 命中的快照。
    func testSeriesPrefetchFetchesItemSeasonsEpisodesAndStoresSnapshot() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])

        app.openDetail(series())
        await awaitPrefetch(app, id: "s-1")

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("seasons"), 1)
        XCTAssertEqual(stub.callCount("episodes"), 1, "首选季的集应在预取时一并拉下")
        let snapshot = try XCTUnwrap(app.detailSnapshot(for: "s-1"), "预取结果应写进快照表")
        XCTAssertEqual(snapshot.detail.name, "学生会也存活！")
        XCTAssertEqual(snapshot.selectedSeasonID, "se-1", "默认季与进页同一套判断")
        XCTAssertEqual(snapshot.episodesBySeason["se-1"]?.map(\.id), ["e-1"])
        // 预取完成后撤槽：下一次 openDetail 不会被 in-flight 表挡住。
        XCTAssertNil(app.detailPrefetchTasks["s-1"])
    }

    /// in-flight 去重：预取未完成时再次点击同一条（快速连点 / 双入口），不重发。
    func testInFlightPrefetchIsDeduplicated() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])

        app.openDetail(series())
        let first = try XCTUnwrap(app.detailPrefetchTasks["s-1"])
        app.openDetail(series()) // 预取仍在途
        await first.value

        XCTAssertEqual(stub.callCount("item"), 1, "连点不应重复发预取请求")
        XCTAssertEqual(stub.callCount("seasons"), 1)
    }

    /// 快照已在 TTL 内（刚从这条详情返回）：预取直接免了，一个请求都不发。
    func testFreshSnapshotSkipsPrefetch() async throws {
        let (app, stub) = try await makeApp()
        app.storeDetailSnapshot(
            .init(detail: series(), seasons: [season()], similar: [],
                  selectedSeasonID: "se-1", episodesBySeason: ["se-1": []]),
            for: "s-1")

        app.openDetail(series())
        try await Task.sleep(for: .milliseconds(20))
        await awaitPrefetch(app, id: "s-1")

        XCTAssertEqual(stub.callCount("item"), 0, "TTL 内的快照不需要预取")
        XCTAssertEqual(stub.callCount("seasons"), 0)
    }

    /// 电影：只发详情一发。不该有季/集的试探请求。
    func testMoviePrefetchFetchesItemOnly() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(MediaItem(id: "m-1", name: "沙丘 2", kind: .movie))

        app.openDetail(MediaItem(id: "m-1", name: "沙丘 2", kind: .movie))
        await awaitPrefetch(app, id: "m-1")

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("seasons"), 0)
        XCTAssertEqual(stub.callCount("episodes"), 0)
        XCTAssertEqual(try XCTUnwrap(app.detailSnapshot(for: "m-1")).detail.name, "沙丘 2")
    }

    /// 合集：详情 + 第一页成员（成员区与合集背景兜底的输入）。
    func testBoxSetPrefetchFetchesMembers() async throws {
        let (app, stub) = try await makeApp()
        let member = MediaItem(id: "m-1", name: "福音战士新剧场版：Q", kind: .movie)
        stub.itemResult = .success(MediaItem(id: "box-1", name: "EVA 系列", kind: .boxSet))
        stub.itemsPageByParent["box-1"] = MediaItemsPage(
            items: [member], startIndex: 0, totalRecordCount: 1)

        app.openDetail(MediaItem(id: "box-1", name: "EVA 系列", kind: .boxSet))
        await awaitPrefetch(app, id: "box-1")

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "合集成员应经 itemsPage 第一页拉下")
        XCTAssertEqual(stub.lastItemsPageQuery?.parentID, "box-1")
        let snapshot = try XCTUnwrap(app.detailSnapshot(for: "box-1"))
        XCTAssertEqual(snapshot.collectionMembers.map(\.id), ["m-1"])
    }
}
