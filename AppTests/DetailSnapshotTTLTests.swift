import CoreModel
import Foundation
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 详情快照的 TTL 短路：快照足够新（本次会话刚拉过 / 点击预取刚落）时，
/// 重进详情页**零请求**原位渲染——「重进秒开」的手感来自这条短路。
///
/// 与 SWR 的分工：SWR（快照旧于 TTL）保证「有内容但不闪骨架屏」，网络照发；
/// TTL 短路（快照新于 TTL）连网络都不发。**磁盘快照不参与 TTL**——`loadFromDisk`
/// 构造快照时把 `fetchedAt` 置 `.distantPast`，磁盘来源（上次会话写穿的）一律走
/// SWR 网络确认，该语义由 `MetadataCacheIntegrationTests.testDetailPrefersNetworkOverCache`
/// 钉住（磁盘数据 + 网络成功 → 必须用网络覆盖）。
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

    private func storeSnapshot(_ app: AppModel, fetchedAt: Date = Date()) {
        app.storeDetailSnapshot(
            .init(detail: series(), seasons: [season()], similar: [],
                  selectedSeasonID: "se-1",
                  episodesBySeason: ["se-1": [episode(id: "e-1", number: 1)]],
                  fetchedAt: fetchedAt),
            for: "s-1")
    }

    /// TTL 内的快照：load() 零网络，整页状态来自快照（含默认季与选中集恢复）。
    func testFreshSnapshotSkipsNetwork() async throws {
        let (app, stub) = try await makeApp()
        storeSnapshot(app)

        // 模拟「点击 → 预取落快照 → 进页」：全新的 VM 实例走 load()。
        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertEqual(stub.callCount("item"), 0, "TTL 内不该再发详情请求")
        XCTAssertEqual(stub.callCount("seasons"), 0, "TTL 内不该再发季请求")
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.displayName, "学生会也存活！")
        XCTAssertEqual(model.selectedSeasonID, "se-1", "默认季应从快照恢复")
        XCTAssertEqual(model.episodes.map(\.id), ["e-1"], "集列表应从快照恢复")
        XCTAssertEqual(model.selectedEpisodeID, "e-1", "默认选中集应从快照恢复")
        XCTAssertNil(model.staleNotice, "TTL 短路不是离线展示")
    }

    /// 超 TTL 的快照：照常走 SWR 网络刷新（快照先行渲染，网络回来原位覆盖）。
    func testExpiredSnapshotStillRefreshes() async throws {
        let (app, stub) = try await makeApp()
        storeSnapshot(app, fetchedAt: Date().addingTimeInterval(-AppModel.detailSnapshotTTL - 10))
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertEqual(stub.callCount("item"), 1, "过 TTL 必须重新确认服务端数据")
        XCTAssertEqual(stub.callCount("seasons"), 1)
        XCTAssertEqual(model.selectedSeasonID, "se-1")
    }

    /// 本地写回（播放返回时的已看状态同步）会重新 storeSnapshot、刷新时间戳——
    /// 也就是续期 TTL。否则「看完一集回详情」5 分钟后重进会白白退化成 SWR 全量刷新。
    func testLocalWriteBackRenewsTTL() async throws {
        let (app, stub) = try await makeApp()
        storeSnapshot(app, fetchedAt: Date().addingTimeInterval(-4 * 60))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load() // TTL 命中：零网络，状态来自快照
        XCTAssertEqual(stub.callCount("item"), 0)

        model.applyPlayState(.init(played: true, percentage: 1, positionSeconds: 0), toItemID: "s-1")

        let refreshed = try XCTUnwrap(app.detailSnapshot(for: "s-1"))
        XCTAssertEqual(
            refreshed.fetchedAt.timeIntervalSinceNow, 0, accuracy: 30,
            "本地写回应刷新快照时间戳（续期 TTL）")
        XCTAssertTrue(refreshed.detail.playState?.played ?? false, "已看状态应写回快照")
    }
}
