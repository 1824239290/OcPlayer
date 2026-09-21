import CoreModel
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 首页三条 rail 的加载：各自独立成败。
///
/// 背景是一台公网中转的 Emby 实测：中位 370ms、长尾到 22s、偶尔整条挂掉，
/// 13 个请求撞满 30s 上限。旧的 `try await (a, b, c)` 元组收口下，**任何一条失败
/// 就把三条全丢**、整页白屏——而另外两条其实已经拿到内容了。
@MainActor
final class HomeRailLoadingTests: XCTestCase {

    /// `loadHome` 成功后会写 rail-presence 提示到 `.standard`；用例跑完要还原，
    /// 别把开发者本机的骨架条数改掉。用 **async** 版 setUp / tearDown：非 async 的
    /// 那两个是 nonisolated 的，碰不到本类的 main-actor 状态。
    private let presenceKey = "dev.jumusu.ocplayer.home.railPresence"
    private var savedPresence: Any?

    override func setUp() async throws {
        savedPresence = UserDefaults.standard.object(forKey: presenceKey)
    }

    override func tearDown() async throws {
        if let savedPresence {
            UserDefaults.standard.set(savedPresence, forKey: presenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: presenceKey)
        }
    }

    private func makeApp(server: StubMediaServer) -> AppModel {
        let app = AppModel()
        app.phase = .ready
        app.server = server
        app.sessionGeneration = 1
        return app
    }

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, kind: .episode)
    }

    /// 一条挂掉，另外两条的内容必须留下。
    func testOneFailingRailKeepsTheOthers() async {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.resumeResult = .failure(JellyfinError(.transport("请求超时。")))
        server.nextUpResult = .success([item("ep-1")])
        server.latestResult = .success([item("m-1")])

        await app.loadHome(server: server, generation: app.sessionGeneration)

        XCTAssertTrue(app.home.resume.isEmpty, "挂掉的那条留空")
        XCTAssertEqual(app.home.nextUp.map(\.id), ["ep-1"], "另外两条必须留下")
        XCTAssertEqual(app.home.latest.map(\.id), ["m-1"])
        XCTAssertNil(app.home.error, "部分失败不该把整页判成错误态——那会遮住已经拿到的内容")
    }

    /// 三条全挂才算这一页失败（`HomeView` 只在 latest 为空时展示整页错误态）。
    func testAllRailsFailingSurfacesError() async {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        let failure = JellyfinError(.transport("请求超时。"))
        server.resumeResult = .failure(failure)
        server.nextUpResult = .failure(failure)
        server.latestResult = .failure(failure)

        await app.loadHome(server: server, generation: app.sessionGeneration)

        XCTAssertNotNil(app.home.error)
        XCTAssertTrue(app.home.latest.isEmpty)
    }

    /// 挂掉的 rail 保留上一次的内容，不清空——比白屏好。
    func testFailedRailKeepsPreviousContent() async {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.resumeResult = .success([item("old-1")])
        server.latestResult = .success([item("m-1")])
        await app.loadHome(server: server, generation: app.sessionGeneration)
        XCTAssertEqual(app.home.resume.map(\.id), ["old-1"])

        server.resumeResult = .failure(JellyfinError(.transport("请求超时。")))
        server.latestResult = .success([item("m-2")])
        await app.loadHome(server: server, generation: app.sessionGeneration)

        XCTAssertEqual(app.home.resume.map(\.id), ["old-1"], "失败时保留旧内容")
        XCTAssertEqual(app.home.latest.map(\.id), ["m-2"], "成功的照常刷新")
    }

    /// 过期 generation 的响应不得写回（换会话 / 换服务器）。
    func testStaleGenerationDoesNotWriteBack() async {
        let server = StubMediaServer()
        let app = makeApp(server: server)
        server.latestResult = .success([item("m-1")])

        await app.loadHome(server: server, generation: app.sessionGeneration - 1)

        XCTAssertTrue(app.home.latest.isEmpty, "过期 generation 的结果应被丢弃")
    }
}
