import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 详情页 stale-while-revalidate 的仓储语义：
/// 内存快照（本会话已确认）零请求；磁盘快照先渲染但必须再走网络确认；
/// 本地已看写回同时更新仓储与 SQLite。
@MainActor
final class DetailSnapshotTTLTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailTTL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DetailTTL-\(UUID().uuidString)"
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

    private func seedDisk(_ app: AppModel) async throws {
        let store = try XCTUnwrap(app.metadata.activeStore)
        let tenant = TenantID(profile: try XCTUnwrap(app.server).profile)
        try await store.saveItems(
            [series(), season(), episode(id: "e-1", number: 1)], tenant: tenant)
    }

    /// 本会话已确认的详情：进页零请求，整页状态来自仓储内存。
    func testFreshRepositoryDetailSkipsNetwork() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])
        await app.metadata.prefetchDetail(itemID: "s-1", kindHint: .series)
        let itemCalls = stub.callCount("item")
        let seasonCalls = stub.callCount("seasons")
        let episodeCalls = stub.callCount("episodes")

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertEqual(stub.callCount("item"), itemCalls, "内存快照内不该再发详情请求")
        XCTAssertEqual(stub.callCount("seasons"), seasonCalls)
        XCTAssertEqual(stub.callCount("episodes"), episodeCalls)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.displayName, "学生会也存活！")
        XCTAssertEqual(model.selectedSeasonID, "se-1")
        XCTAssertEqual(model.episodes.map(\.id), ["e-1"])
        XCTAssertEqual(model.selectedEpisodeID, "e-1")
        XCTAssertNil(model.staleNotice, "会话内确认过的内容不是离线展示")
    }

    /// 磁盘快照先渲染，但网络必须再确认一次（离线兜底不牺牲新鲜度）。
    func testDiskDetailRendersFirstThenConfirmsWithNetwork() async throws {
        let (app, stub) = try await makeApp()
        try await seedDisk(app)
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertEqual(stub.callCount("item"), 1, "磁盘来源必须网络确认")
        XCTAssertEqual(stub.callCount("seasons"), 1)
        XCTAssertEqual(stub.callCount("episodes"), 1)
        XCTAssertEqual(model.selectedSeasonID, "se-1")
        XCTAssertEqual(model.episodes.map(\.id), ["e-1"])
    }

    /// 网络失败时磁盘内容留在屏幕上，并给出离线/过期提示。
    func testDiskContentSurvivesFailedRefreshWithStaleNotice() async throws {
        let (app, stub) = try await makeApp()
        try await seedDisk(app)
        stub.itemResult = .failure(JellyfinError(.noNetwork))
        stub.seasonsResult = .failure(JellyfinError(.noNetwork))
        stub.episodesResult = .failure(JellyfinError(.noNetwork))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertEqual(model.displayName, "学生会也存活！", "失败不得清空磁盘内容")
        XCTAssertNil(model.loadError, "有内容时不落整页错误")
        XCTAssertNotNil(model.staleNotice)
        XCTAssertTrue(model.staleNotice?.causedByConnectivity == true)
    }

    /// 本地已看写回：仓储内存 + SQLite 同一拍更新。
    func testLocalPlayStateWriteBackUpdatesRepositoryAndStore() async throws {
        let (app, stub) = try await makeApp()
        try await seedDisk(app)
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])
        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        let state = MediaItem.PlayState(played: true, percentage: 1, positionSeconds: 120)
        await model.applyPlayState(state, toItemID: "e-1")

        let detailValue = await app.metadata.cachedDetail(itemID: "s-1")?.value
        let detail = try XCTUnwrap(detailValue)
        XCTAssertEqual(detail.episodes.first?.playState, state)

        let store = try XCTUnwrap(app.metadata.activeStore)
        let tenant = TenantID(profile: try XCTUnwrap(app.server).profile)
        let cached = try await store.item("e-1", tenant: tenant)
        XCTAssertEqual(cached?.item.playState, state)
        XCTAssertNotNil(cached?.progressFetchedAt)
    }
    func testOldDetailCannotWritePlayStateToNewSessionWithSameItemID() async throws {
        let (app, _) = try await makeApp()
        try await seedDisk(app)
        let model = DetailViewModel(item: series())
        model.attach(app)
        let newServer = StubMediaServer(profileID: "new:user")
        app.resetBrowseState()
        app.server = newServer
        let store = try XCTUnwrap(app.metadata.activeStore)
        let tenant = TenantID(profile: newServer.profile)
        try await store.saveItems([episode(id: "e-1", number: 1)], tenant: tenant)
        let state = MediaItem.PlayState(played: true, percentage: 1, positionSeconds: 120)
        await model.applyPlayState(state, toItemID: "e-1")
        let cached = try await store.item("e-1", tenant: tenant)
        XCTAssertNotEqual(cached?.item.playState, state)
    }

}
