import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 详情页选集分区的**接线**：真 VM 走一遍集列表加载后，`episodeChunks` 要按 30 集
/// 切出来，并与 `episodeSlots` 逐位一致。
///
/// 纯分段策略（切点 / 标签 / 编号兜底）在 `MetadataKit` 的 `EpisodeChunkTests` 里钉；
/// 这里只钉「分区与轨道由同一个出口派生」——视图拿分区去切轨道，两者一旦漂开，
/// 症状是「点 31-60 却看到 1-30」，而单测策略层是测不出来的。
///
/// 搭法与 `DetailLoadCancellationTests.makeApp` 同构：真 `AppModel` + 临时目录 SQLite
/// + 替身服务器，全程离线。
@MainActor
final class DetailEpisodeChunkTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailChunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DetailChunk-\(UUID().uuidString)"
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

    private func series() -> MediaItem {
        MediaItem(id: "s-1", name: "长番", kind: .series)
    }

    private func season() -> MediaItem {
        MediaItem(id: "se-1", name: "第 1 季", kind: .season, seriesID: "s-1", seasonNumber: 1)
    }

    private func episode(_ number: Int) -> MediaItem {
        MediaItem(id: "e-\(number)", name: "第 \(number) 集", kind: .episode,
                  seriesID: "s-1", seasonNumber: 1, episodeNumber: number)
    }

    /// 35 集 → 两段：`1-30` 与只剩 5 集的尾段 `31-35`。
    func testChunksRebuiltFromLoadedEpisodes() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success((1...35).map(episode))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        XCTAssertEqual(model.episodeSlots.count, 35, "前置：集列表已就位")
        XCTAssertEqual(model.episodeChunks.map(\.rangeLabel), ["1-30", "31-35"])
        XCTAssertEqual(
            model.episodeChunks.flatMap(\.slots).map(\.id),
            model.episodeSlots.map(\.id),
            "分区必须保序覆盖整条轨道，否则视图按分区切出来的格子会错段"
        )
    }

    /// 关掉「显示未入库占位」走的是 `rebuildEpisodeSlots` 的另一条早退分支：
    /// 分区必须照样算出来，否则长番一关占位就退回一条要滑几百张卡的长轨道。
    func testChunksAlsoRebuiltWhenPlaceholdersDisabled() async throws {
        let (app, stub) = try await makeApp()
        app.tmdb.setShowPlaceholders(false)
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success((1...31).map(episode))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        XCTAssertEqual(model.episodeChunks.map(\.rangeLabel), ["1-30", "31"])
    }

    /// 30 集（含）以内只有一段：详情页据此**不渲染**分区条，普通季的观感与改动前一致。
    func testSingleChunkAtOrBelowThreshold() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .success((1...24).map(episode))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        XCTAssertEqual(model.episodeChunks.count, 1)
        XCTAssertEqual(model.episodeChunks.first?.rangeLabel, "1-24")
    }
}
