import AppDesignKit
import CoreModel
@testable import OcPlayer
import XCTest

/// 氛围池的装载与生命周期。
///
/// 这套用例守的是一条**只在冷启动抢跑时才出错**的路径：池子装不上 → `homeAmbience`
/// 恒 nil → iOS 上所有自垫背景的页面整个会话停在纯色底（macOS 靠整窗层不显，
/// 所以这病在 Mac 上根本看不见）。实机判例见 `BackdropCarouselTriggerTests` 头注释。
///
/// 判据里的「不记账」是这套逻辑的命门：装载失败时**不能**推进 `ambienceLoadedGeneration`，
/// 否则触发键稳定下来、再也没人重试——那正是 `fb36f14` 的病。
@MainActor
final class AmbiencePoolTests: XCTestCase {

    /// 预热调用的记录点。
    ///
    /// 刻意用**静态容器**而不是测试实例的属性：预热钩子是个逃逸闭包，捕获测试实例
    /// 会让编译器判"Sending 'self' risks causing data races"（XCTestCase 的
    /// `setUp` 是 nonisolated 的，而闭包要在主 actor 上跑）。静态容器不捕获 self，
    /// 也就没有这条歧义。
    @MainActor
    private enum WarmRecorder {
        static var calls: [(url: URL, authHeader: String?)] = []
    }

    private var warmCalls: [(url: URL, authHeader: String?)] { WarmRecorder.calls }

    override func setUp() {
        super.setUp()
        WarmRecorder.calls = []
        // 生产走 `ImagePipeline`（会真发请求、`stub.local` 的 DNS 还可能拖住用例），
        // 用例里换成"记录调用、立刻返回"。
        AmbienceImageWarmup.warm = { url, authHeader, _ in
            WarmRecorder.calls.append((url, authHeader))
        }
    }

    override func tearDown() {
        AmbienceImageWarmup.warm = { url, authHeader, maxPixelSize in
            _ = try? await ImagePipeline.shared.load(
                url, authHeader: authHeader, maxPixelSize: maxPixelSize
            )
        }
        WarmRecorder.calls = []
        super.tearDown()
    }

    // MARK: - 夹具

    /// 带 backdrop 的条目：`imageTarget(.backdrop)` 只在 `backdropImageTag` 非 nil 时
    /// 出 URL（"没有 tag 就不发请求"那条规则），所以夹具必须给 tag。
    private func item(_ id: String, tag: String? = nil) -> MediaItem {
        MediaItem(id: id, name: "条目 \(id)", kind: .movie, backdropImageTag: tag ?? "tag-\(id)")
    }

    private func makeApp(server: StubMediaServer = StubMediaServer()) -> AppModel {
        let app = AppModel()
        app.phase = .ready
        app.server = server
        app.serverEndpointURL = server.profile.baseURL
        return app
    }

    // MARK: - 正常装载

    func testLoadsPoolFromRandomQueryAndPublishesCurrentAmbience() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success((1...12).map { item("m\($0)") })
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(app.ambiencePool.count, AmbiencePool.poolSize, "池子上限是随机池大小")
        XCTAssertEqual(app.ambienceLoadedGeneration, app.sessionGeneration, "装载成功才记账")
        XCTAssertEqual(app.ambienceLoadedEndpoint, server.profile.baseURL.absoluteString)
        XCTAssertNotNil(app.homeAmbience, "池子就绪要立刻声明当前那张，页面才拿得到背景")
        XCTAssertEqual(server.callCount("randomBackdropItems"), 1)
    }

    /// 没有 backdrop tag 的条目不能进池——它们取不出 URL，进池等于让页面停在纯色底。
    func testSkipsItemsWithoutBackdropTag() async {
        let server = StubMediaServer()
        var withoutTag = MediaItem(id: "no-art", name: "没图", kind: .movie)
        withoutTag.backdropImageTag = nil
        server.randomBackdropResult = .success([withoutTag, item("m1")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(app.ambiencePool.map(\.id), ["m1"])
    }

    /// 重复条目要去重（服务端随机查询可能给出重复项）。
    func testDeduplicatesPoolItems() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1"), item("m1"), item("m2")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(app.ambiencePool.map(\.id).sorted(), ["m1", "m2"])
    }

    /// 首图预热完成**才**让池子非空（否则首页一进来先闪一块灰占位）。
    func testPremiumWarmsFirstImageBeforePoolBecomesVisible() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1"), item("m2")])
        let app = makeApp(server: server)
        var poolWasEmptyWhenWarmingFirstImage = false

        AmbienceImageWarmup.warm = { url, authHeader, _ in
            WarmRecorder.calls.append((url, authHeader))
            // 预热回调里读池子：此刻必须还是空的（顺序断言）。
            if WarmRecorder.calls.count == 1 {
                poolWasEmptyWhenWarmingFirstImage = app.ambiencePool.isEmpty
            }
        }

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(warmCalls.count, 1, "装载阶段只预热首图，其余留给换片前的批量预热")
        XCTAssertTrue(poolWasEmptyWhenWarmingFirstImage, "预热必须先于「池子非空」")
        XCTAssertFalse(app.ambiencePool.isEmpty)
    }

    // MARK: - 失败不记账（命门）

    func testFailedLoadDoesNotRecordAndRetriesWhenTriggerChanges() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .failure(URLError(.notConnectedToInternet))
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertTrue(app.ambiencePool.isEmpty)
        XCTAssertNil(app.ambienceLoadedGeneration, "失败绝不能记账，否则这个会话再也不会重试")
        XCTAssertNil(app.homeAmbience)

        // 首页数据到位 = 一次补救机会：触发键变化后重跑，这回服务器给了图。
        server.randomBackdropResult = .success([item("m1")])
        let triggerBefore = app.ambienceTrigger
        app.home = AppModel.HomeData(resume: [MediaItem(id: "ep", name: "一集", kind: .episode)])
        XCTAssertNotEqual(app.ambienceTrigger, triggerBefore, "首页数据到位必须改变触发键，否则 .task 不会重跑")

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(app.ambiencePool.map(\.id), ["m1"])
        XCTAssertEqual(app.ambienceLoadedGeneration, app.sessionGeneration)
    }

    /// 随机查询与首页回退源**同时为空**（冷启动抢跑现场）：池子留空、不记账。
    func testColdStartRaceLeavesPoolEmptyWithoutRecording() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .failure(URLError(.cannotConnectToHost))
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertTrue(app.ambiencePool.isEmpty)
        XCTAssertNil(app.ambienceLoadedGeneration)
        XCTAssertFalse(app.homeHasAmbienceFallback)
    }

    /// 随机查询失败但首页已有条目：走回退源装池（服务器不支持随机查询时的通路）。
    func testFallsBackToHomeItemsWhenRandomQueryFails() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .failure(URLError(.badServerResponse))
        let app = makeApp(server: server)
        app.home = AppModel.HomeData(
            resume: [item("m2")],
            nextUp: [],
            latest: [item("m1")])
        await app.loadAmbiencePoolIfNeeded()

        XCTAssertNotNil(app.ambienceLoadedGeneration, "回退源装上了就该记账")
        XCTAssertEqual(Set(app.ambiencePool.map(\.id)), ["m1", "m2"])
    }

    /// 服务器与首页都没有 item：池空，且**不留** `homeAmbience`。
    func testEmptyEverythingLeavesNoAmbience() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertNil(app.currentAmbienceItem)
        XCTAssertNil(app.homeAmbience)
        XCTAssertNil(app.ambienceLoadedGeneration)
    }

    // MARK: - 重拉条件

    func testSameGenerationAndEndpointDoesNotReload() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()
        let firstPool = app.ambiencePool
        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(server.callCount("randomBackdropItems"), 1, "同代次同地址不该重拉")
        XCTAssertEqual(app.ambiencePool.map(\.id), firstPool.map(\.id))
    }

    func testSessionChangeReloadsPool() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()
        XCTAssertEqual(server.callCount("randomBackdropItems"), 1)

        // 会话边界（`resetBrowseState`）：池子连条目一起清，代次自增。
        app.resetAmbiencePool()
        app.sessionGeneration &+= 1
        server.randomBackdropResult = .success([item("m2")])

        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(app.ambiencePool.map(\.id), ["m2"], "新会话必须重拉")
        XCTAssertEqual(server.callCount("randomBackdropItems"), 2)
    }

    func testEndpointChangeReloadsPool() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()
        // 地址决议换了一条（局域网 → Tailscale）：池里的 URL 全失效。
        app.serverEndpointURL = URL(string: "http://100.64.0.1:8096")!
        await app.loadAmbiencePoolIfNeeded()

        XCTAssertEqual(server.callCount("randomBackdropItems"), 2)
    }

    /// 会话重置要把池子与声明一起清掉：池里的图片 URL 带着**旧服务器的 authHeader**，
    /// 留着会让新会话首屏拿旧凭据去请求图片。
    func testSessionResetClearsPoolAndPublishedAmbience() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1")])
        let app = makeApp(server: server)
        app.home = AppModel.HomeData(resume: [], nextUp: [], latest: [item("m2")])
        await app.loadAmbiencePoolIfNeeded()
        XCTAssertNotNil(app.homeAmbience)

        app.signOut()

        XCTAssertTrue(app.ambiencePool.isEmpty)
        XCTAssertNil(app.ambienceLoadedGeneration)
        XCTAssertNil(app.homeAmbience)
        XCTAssertFalse(app.homeHasAmbienceFallback, "首页数据也随会话清了")
    }

    // MARK: - 换片循环

    /// `reduceMotion` 下只保留静态首图：不轮换。
    func testReduceMotionKeepsStaticFirstImage() async {
        let server = StubMediaServer()
        let items = (1...3).map { item("m\($0)") }
        server.randomBackdropResult = .success(items)
        let app = makeApp(server: server)
        app.reduceMotion = true

        await app.loadAmbiencePoolIfNeeded()
        let pool = app.ambiencePool
        XCTAssertEqual(pool.count, 3)

        // 直接跑一次预热+循环：reduceMotion 下它必须立刻返回，index 不动。
        // 不等待 12s——那会让用例慢得没人愿意跑；这里断言的是入口处的闸门。
        let started = Date()
        await app.warmUpAndRotateAmbience()

        XCTAssertEqual(app.ambienceIndex, 0, "减弱动态效果下不轮换")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "不该进入等待 12s 的换片循环")
    }

    /// 空池时 `warmUpAndRotateAmbience` 立刻返回（不空转、不崩）。
    func testRotateReturnsImmediatelyForEmptyPool() async {
        let app = makeApp()
        await app.warmUpAndRotateAmbience()
        XCTAssertEqual(app.ambienceIndex, 0)
        XCTAssertNil(app.currentAmbienceItem)
    }

    /// `publishCurrentAmbience` 在空池时**不清**已有声明：上一张仍然可用
    /// （URL 未变、缓存命中），清了反而让正在看它的页面闪一下纯色底。
    func testPublishKeepsPreviousAmbienceWhenPoolIsEmpty() async {
        let app = makeApp()
        let previous = WindowAmbience(url: URL(string: "https://example.com/a.jpg"), authHeader: nil)
        app.homeAmbience = previous

        app.publishCurrentAmbience()

        XCTAssertEqual(app.homeAmbience, previous)
    }

    /// `currentAmbienceItem` 按池长取模，池子缩短时不会越界。
    func testCurrentItemWrapsIndexWithinPoolBounds() async {
        let server = StubMediaServer()
        server.randomBackdropResult = .success([item("m1"), item("m2")])
        let app = makeApp(server: server)

        await app.loadAmbiencePoolIfNeeded()
        XCTAssertNotNil(app.currentAmbienceItem)

        // 只有 2 条时 index 也只会落在 0/1——这里直接断言池长取模的边界。
        XCTAssertEqual(app.ambiencePool[app.ambienceIndex % app.ambiencePool.count].id,
                       app.currentAmbienceItem?.id)
    }
}
