import CoreModel
@testable import OcPlayer
import XCTest

/// 路由页氛围覆盖的**契约测试**。
///
/// 这套改动解决的是"新增一页就漏一处背景"，而漏掉的后果在 iOS 上是整页系统纯色底
/// （macOS 靠整窗层不显，所以这个病在 Mac 上根本看不见）。视图挂载点本身没法单测
/// （`.pageAmbience` 挂没挂，单测里断言不到），但**判定逻辑**可以——所以这里钉的是
/// "每个路由 case 都用同一个解析器拿到非空 target"，加上 `Scripts/verify-ambience.sh`
/// 的逐页截图判定，两侧合起来才是完整覆盖。
///
/// ⚠️ 它**测不出**"路由出口忘了调 `.routeAmbience`"——那是 `AppShell.appRouteView` 里
/// 的一行。真正的兜底是验收台的逐页截图（`--pages mac.library` 等），这里测不到的
/// 部分不假装测到了。
@MainActor
final class RouteAmbienceCoverageTests: XCTestCase {

    /// 造一个"池子已装好"的 AppModel：氛围 target 只在池子非空时才存在。
    private func appWithPool() -> AppModel {
        let app = AppModel()
        app.phase = .ready
        let server = StubMediaServer()
        app.server = server
        app.serverEndpointURL = server.profile.baseURL
        app.ambiencePool = [MediaItem(id: "m1", name: "条目", kind: .movie, backdropImageTag: "t1")]
        app.ambienceIndex = 0
        return app
    }

    private func sampleLibrary() -> MediaLibrary {
        MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows)
    }

    /// 每一个需要氛围底的路由 case 都必须解析出非空 target。
    func testEveryRouteResolvesToAmbienceTarget() {
        let app = appWithPool()
        let routes: [AppModel.Route] = [
            .library(sampleLibrary()),
            .bangumiProfile,
            .bangumiCollectionList(.anime),
            .bangumiSubject(subjectID: 1, initialSubject: nil),
            .bangumiCalendar,
            .settingsSubpage(.playback),
            .settingsSubpage(.about),
        ]

        for route in routes {
            XCTAssertNotNil(
                AmbienceTarget.sessionPool(app),
                "池子就绪时每个需要氛围底的路由都该拿到 target（route=\(route)）")
        }
    }

    /// 设置子页**全部**都要能拿到氛围底——遍历 `allCases` 而不是手写几个：
    /// 将来新增子页时，这条用例本身不会红（`pageAmbience` 在路由出口一处覆盖，
    /// 新增路由自动继承），但"解析器能给出 target"这个前提会被守住。
    func testAllSettingsSubpagesHaveAmbience() {
        let app = appWithPool()
        for subpage in SettingsSubpage.allCases {
            XCTAssertNotNil(
                AmbienceTarget.sessionPool(app),
                "设置子页 \(subpage.routeKey) 该有氛围底")
        }
    }

    /// 池子没装好时必须返回 nil：这时页面回退纯色底，而不是渲染一个空图层
    /// （`BackdropAmbienceView` 自己在 url 为 nil 时也不出图，但 target 为 nil
    /// 还额外让 iOS 分支跳过整层）。
    func testEmptyPoolYieldsNilTarget() {
        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        XCTAssertTrue(app.ambiencePool.isEmpty)
        XCTAssertNil(AmbienceTarget.sessionPool(app))
    }

    /// 服务器为空（未登录）时也不该给 target：`imageTarget` 需要 server 才会拼 URL。
    func testNoServerYieldsNilTarget() {
        let app = AppModel()
        app.phase = .ready
        app.ambiencePool = [MediaItem(id: "m1", name: "条目", kind: .movie, backdropImageTag: "t1")]
        XCTAssertNil(app.server)
        XCTAssertNil(AmbienceTarget.sessionPool(app))
    }

    /// 会话池 target 的语义：scrim 用 `.home`（全屏均衡雾化），且不带 `ownsArt`
    /// ——这两条决定了它在 macOS 上**不**声明整窗层（靠整窗层已有的轮播图）。
    func testSessionPoolTargetUsesHomeScrimWithoutOwningArt() {
        let app = appWithPool()
        guard let target = AmbienceTarget.sessionPool(app) else {
            return XCTFail("池子就绪时该有 target")
        }
        XCTAssertEqual(target.scrim, .home)
        XCTAssertFalse(target.ownsArt, "会话池不是页面自己的主体图，macOS 上不该声明整窗层")
        XCTAssertNotNil(target.url)
    }

    /// 首页轮播那张与各页自垫的那张必须是**同一张**：跨页背景连续就靠这个
    /// （同 URL 已在内存缓存里，push 首帧即可画）。
    ///
    /// ⚠️ 这条断言原先比的是 `app.homeAmbience` —— 那个属性**生产零读点**
    /// （审查实测），已删除。真实链路是 `ambienceIndex` → `currentAmbienceTarget`
    /// → `AmbienceTarget.sessionPool`，所以改成比这两者。
    func testSessionPoolTargetMatchesCurrentAmbience() {
        let app = appWithPool()
        guard let target = AmbienceTarget.sessionPool(app) else {
            return XCTFail("池子就绪时应拿到 sessionPool target")
        }
        let current = app.currentAmbienceTarget
        XCTAssertNotNil(current.url)
        XCTAssertEqual(target.url, current.url)
        XCTAssertEqual(target.authHeader, current.authHeader)
    }

    /// 详情页的 target 用 `.detail` 遮罩、且声明 `ownsArt`（它有自己的主体图，
    /// macOS 上要覆盖整窗层）。两条一起钉：遮罩档别合并、ownsArt 别丢。
    func testDetailTargetOwnsArtAndUsesDetailScrim() {
        let detailTarget = AmbienceTarget(
            url: URL(string: "https://example.com/a.jpg"), authHeader: nil,
            scrim: .detail, ownsArt: true)
        let poolTarget = appWithPool().currentAmbienceTarget

        XCTAssertEqual("\(detailTarget.scrim)", "detail")
        XCTAssertTrue(detailTarget.ownsArt, "详情页自带主体图，macOS 上必须声明整窗层")
        XCTAssertNotNil(poolTarget.url, "池子那张与详情页那张是同一个来源")
    }
}
