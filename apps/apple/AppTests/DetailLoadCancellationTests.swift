import CoreModel
import Foundation
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 详情页三条加载路径对「任务取消」的分类：**取消不是失败**。
///
/// 背景（2026-10-11 实测排查）：进剧集详情页后集列表请求被页面层取消（macOS 26 上
/// `.task` 被取消且不重启），URLSession 抛的是 `URLError`（NSURLErrorDomain, -999），
/// 与 `CancellationError` **无子型关系**——`catch is CancellationError` 接不住它，
/// 裸 NSError 全文被写进 `episodeLoadError`，页面挂出「集列表加载失败」且那次访问
/// 永远不自愈。这组用例钉住四件事：取消不产生错误态、取消后排一次静默补拉、
/// 成功路径洗掉陈旧错误、补拉有防风暴上限。
@MainActor
final class DetailLoadCancellationTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DetailCancel-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    /// 与 `CollectionDetailTests.makeApp` 同构的离线环境：真 AppModel + 临时目录 SQLite。
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
        MediaItem(id: id, name: "第 \(number) 季", kind: .season, seriesID: "s-1", seasonNumber: number)
    }

    private func episode(id: String, number: Int) -> MediaItem {
        MediaItem(id: id, name: "第 \(number) 集", kind: .episode,
                  seriesID: "s-1", seasonNumber: 1, episodeNumber: number)
    }

    // MARK: - 集列表：取消的分类与补拉

    /// 集列表请求被取消（URLError -999）：不写错误条，排一次补拉；补拉成功后
    /// 集列表就位、计数复位。这是 2026-10-11 线上症状的直拍。
    func testEpisodeCancellationIsSilentAndSchedulesReload() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .success(series())
        stub.seasonsResult = .success([season()])
        stub.episodesResult = .failure(URLError(URLError.cancelled))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()
        XCTAssertEqual(model.selectedSeasonID, "se-1", "前置：load() 已选出默认季")

        // 生产路径里这步由视图的 `.task(id: selectedSeasonID)` 触发。
        await model.loadEpisodes()

        XCTAssertNil(model.episodeLoadError, "取消不是错误，不能把 URLError -999 写进错误条")
        XCTAssertFalse(model.isLoadingEpisodes)
        XCTAssertNotNil(model.episodeReloadTask, "取消后应排一次静默补拉")
        XCTAssertEqual(model.episodeReloadAttemptCount, 1)

        // 补拉落桩：翻成成功后等补拉任务跑完，集列表应当就位。
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])
        await model.episodeReloadTask?.value

        XCTAssertEqual(model.episodes.map(\.id), ["e-1"], "补拉应把集列表拉回来")
        XCTAssertNil(model.episodeLoadError)
        XCTAssertEqual(model.episodeReloadAttemptCount, 0, "成功后补拉计数复位")
    }

    /// 成功路径洗掉陈旧错误：上一轮取消把错误写进状态后，任何一次成功加载
    /// （含缓存命中）都该把它清掉，不能让错误条驻留到永远。
    func testStaleEpisodeErrorClearsOnSuccess() async throws {
        let (app, stub) = try await makeApp()
        stub.episodesResult = .success([episode(id: "e-1", number: 1)])

        let model = DetailViewModel(item: series())
        model.attach(app)
        model.seasons = [season()]
        model.selectedSeasonID = "se-1"
        model.episodeLoadError = "Error Domain=NSURLErrorDomain Code=-999 （陈旧错误）"

        await model.loadEpisodes()

        XCTAssertNil(model.episodeLoadError, "成功加载后陈旧错误应被清空")
        XCTAssertEqual(model.episodes.map(\.id), ["e-1"])
    }

    /// 补拉有上限：同一轮访问最多补拉 2 次，取消风暴不会变成无限循环。
    func testEpisodeReloadAttemptsAreCapped() async throws {
        let (app, stub) = try await makeApp()
        stub.episodesResult = .failure(URLError(URLError.cancelled))

        let model = DetailViewModel(item: series())
        model.attach(app)
        model.seasons = [season()]
        model.selectedSeasonID = "se-1"

        await model.loadEpisodes()
        await model.loadEpisodes()
        await model.loadEpisodes()

        XCTAssertEqual(model.episodeReloadAttemptCount, 2, "三次取消只应排出两次补拉")
    }

    // MARK: - 详情整页：取消不该误报「刷新失败」

    /// 首拉详情被取消：不写 loadError（否则整页裸 dump）、不置 staleNotice、
    /// isLoading 正常收尾。旧代码在这里产出整页的 `Error Domain=…` 裸串。
    func testDetailLoadCancellationIsNotAnError() async throws {
        let (app, stub) = try await makeApp()
        stub.itemResult = .failure(URLError(URLError.cancelled))

        let model = DetailViewModel(item: series())
        model.attach(app)
        await model.load()

        XCTAssertNil(model.loadError, "取消不该写整页错误")
        XCTAssertNil(model.staleNotice, "取消不该被当成「正在展示缓存」")
        XCTAssertFalse(model.isLoading, "取消后加载态应收尾")
    }

    // MARK: - 合集成员：同款分类漏洞

    /// 成员分页被取消：静默返回，不写 membersLoadError（旧代码裸 dump 同款）。
    func testMembersCancellationIsSilent() async throws {
        let (app, stub) = try await makeApp()
        stub.itemsPageResult = .failure(URLError(URLError.cancelled))

        let box = MediaItem(id: "box-1", name: "合集", kind: .boxSet)
        let model = DetailViewModel(item: box)
        model.attach(app)
        await model.loadMembers(reset: true)

        XCTAssertNil(model.membersLoadError, "取消不该写成员错误条")
        XCTAssertFalse(model.isLoadingMembers)
    }
}
