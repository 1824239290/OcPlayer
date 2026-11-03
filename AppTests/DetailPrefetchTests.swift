import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 详情页点击预取：预取与进页刷新共用仓储的同一个单飞任务，
/// 因此「预取一轮、进页再一轮」的重复请求在结构上不存在。
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

    private func cachedDetail(_ app: AppModel, id: String) async -> MediaDetailContent? {
        await app.metadata.cachedDetail(itemID: id)?.value
    }

    /// series：一轮拉齐 item + 季 + 首选季的集，并写进仓储。
    func testSeriesPrefetchFetchesItemSeasonsAndEpisodes() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])

        let task = try XCTUnwrap(app.prefetchDetail(for: series()))
        await task.value

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("seasons"), 1)
        XCTAssertEqual(stub.callCount("episodes"), 1)
        let snapshotValue = await cachedDetail(app, id: "s-1")
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.item.name, "学生会也存活！")
        XCTAssertEqual(snapshot.episodesSeasonID, "se-1")
        XCTAssertEqual(snapshot.episodes.map(\.id), ["e-1"])
    }

    /// in-flight 去重：预取在途时再次点击同一条，不重发。
    func testInFlightPrefetchIsDeduplicated() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])

        let first = try XCTUnwrap(app.prefetchDetail(for: series()))
        try await Task.sleep(for: .milliseconds(20))
        let second = try XCTUnwrap(app.prefetchDetail(for: series()))
        await first.value
        await second.value

        XCTAssertEqual(stub.callCount("item"), 1, "连点不应重复发预取请求")
    }

    /// 已经确认过的详情再点一次：仓储内存命中，零网络。
    func testFreshPrefetchSkipsNetwork() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])

        await app.prefetchDetail(for: series())?.value
        let before = stub.callCount("item")
        await app.prefetchDetail(for: series())?.value

        XCTAssertEqual(stub.callCount("item"), before, "内存已确认的详情不再预取")
    }

    /// 电影：只发详情，不白拉季列表。
    func testMoviePrefetchFetchesOnlyItem() async throws {
        let (app, stub) = try await makeApp()
        let movie = MediaItem(id: "m-1", name: "沙丘 2", kind: .movie)
        stub.itemResult = .success(movie)

        await app.prefetchDetail(for: movie)?.value

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("seasons"), 0)
        let snapshotValue = await cachedDetail(app, id: "m-1")
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.item.name, "沙丘 2")
    }

    /// 合集：详情 + 第一页成员一起落仓储（背景兜底与成员区都靠它）。
    func testBoxSetPrefetchFetchesMembers() async throws {
        let (app, stub) = try await makeApp()
        let box = MediaItem(id: "box-1", name: "EVA", kind: .boxSet)
        stub.itemResult = .success(box)
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [MediaItem(id: "m-1", name: "序", kind: .movie)], startIndex: 0,
            totalRecordCount: 1))

        await app.prefetchDetail(for: box)?.value

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("itemsPage"), 1)
        let snapshotValue = await cachedDetail(app, id: "box-1")
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.collectionMembers.map(\.id), ["m-1"])
    }
}
