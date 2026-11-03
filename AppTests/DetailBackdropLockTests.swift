import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 详情页背景图的**锁定语义**在 `DetailViewModel` 这一层的行为（真 `AppModel` + 真 SQLite +
/// 替身服务器，**全部离线**）。
///
/// 为什么要单独一组：`BackdropSourceLatch` 的 6 条单测钉住的是那个**值类型状态机**的行为，
/// 但 2026-11-03 之后生产路径已经改成「`resolveBackdropSource()` 一次性算好、写进
/// `lockedBackdropTargets`、`backdropTarget(width:)` 只读」。也就是说状态机那套 `mutating`
/// 入口已不再上屏（见 `BackdropSourceLatch.swift` 的收口说明）。锁定语义若要继续成立，
/// **断言必须活在真正上屏的那一层**——就是这里。
///
/// 覆盖的是三条容易「看起来接好了、其实没测到」的：
/// 1. **②→③ 方向**：服务端图先锁定，迟到的 TMDB overlay 不许顶掉它。
///    （用户报的闪图就是这个方向。旧的 `testLateContentBackdropIsLockedOnce` 测的是
///    ②→②′「详情 tag 变了」，不是同一个方向，替代不了本条。）
/// 2. **宽度档独立**：800（模糊/氛围档）与 1600（清晰档）是两个 URL，不能共用一个锁槽。
/// 3. **凭证跟着锁定的图走**：锁的是服务端图就带服务端 token；锁成 TMDB 图就不该带。
///    串了就是把 Jellyfin 凭证发给 CDN。
@MainActor
final class DetailBackdropLockTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailBackdropLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DetailBackdropLock-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    /// 真 `AppModel`（真 SQLite 仓储）+ 替身服务器。与 `CollectionDetailTests.makeApp`
    /// 同形——刻意不复用：那是另一个人的文件，跨文件共享 helper 会让两侧改动互相牵制。
    private func makeApp(configureKey: Bool = true) async throws -> (AppModel, StubMediaServer, MetadataStore) {
        if configureKey {
            defaults.set("0123456789abcdef0123456789abcdef",
                         forKey: TMDbCredentialStore.defaultsKey)
        }
        let app = AppModel(
            tmdb: TMDbCoordinator(defaults: try XCTUnwrap(defaults), sessionConfiguration: nil),
            preferences: try XCTUnwrap(defaults))
        app.metadata.setup(directory: directory)
        let ready = await app.metadata.waitUntilReady()
        XCTAssertTrue(ready, "临时目录建库应成功")
        let store = try XCTUnwrap(app.metadata.activeStore)
        // 补全服务由 `AppModel.bootstrap()` 在生产路径装配；测试宿主整段跳过 bootstrap，
        // 这里补上同一步，否则 `enricher` 恒为 nil、overlay 永远读不到，用例会「碰巧通过」。
        app.tmdb.attach(store: store)
        let stub = StubMediaServer()
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        return (app, stub, store)
    }

    // MARK: - ②→③：迟到的 TMDB overlay 不许顶掉已锁的服务端图

    /// 用户报的「后台图出来后马上被 TMDB 替代」就是这个方向。
    ///
    /// 时序按真实 `load()` 复刻：
    /// 1. 解析那一刻本机**没有** TMDB 缓存（没有 link/payload）⇒ 算不出图，一个档都不锁；
    /// 2. 详情落到地、服务端图 tag 出现 ⇒ `detail.didSet` 补锁服务端图；
    /// 3. 后台 TMDB 补齐落库后再读一次 overlay（等价于 `loadTMDbOverlay()` 的 apply）⇒
    ///    现算规则此刻会给出 TMDB 图，但已锁的档**不许改口**。
    ///
    /// 中间那条 `XCTAssertNotEqual(unlockedRule, locked)` 是**控制断言**：它证明此刻
    /// 现算规则确实会改口。没有它，本用例在「overlay 根本没到」时也会绿——那就是空跑。
    func testLateTMDbOverlayDoesNotReplaceLockedServerBackdrop() async throws {
        let (app, stub, store) = try await makeApp()
        let tenant = TenantID(profile: stub.profile)
        let listItem = MediaItem(id: "s-1", name: "服务端标题", kind: .series)

        let model = DetailViewModel(item: listItem)
        model.attach(app)

        // 1) 解析时没有 TMDB 缓存：无图可算，不锁。
        await model.resolveBackdropSource()
        XCTAssertTrue(model.isBackdropSourceResolved)
        XCTAssertNil(model.backdropTarget(width: 800).url,
                     "解析那一刻既无服务端 tag 也无 TMDB 缓存，本来就该是 nil")

        // 2) 详情落地：服务端图出现 ⇒ 补锁。
        let landed = MediaItem(id: "s-1", name: "服务端标题", kind: .series,
                               backdropImageTag: "server-bd")
        model.detail = landed
        let lockedURL = try XCTUnwrap(model.backdropTarget(width: 800).url,
                                      "详情落地必须补锁上服务端图")
        XCTAssertTrue(lockedURL.absoluteString.contains("server-bd"))
        let lockedHeader = model.backdropTarget(width: 800).authHeader
        XCTAssertEqual(lockedHeader, stub.authorizationHeader,
                       "锁定的是服务端图，凭证就该是服务端的")

        // 3) 后台 TMDB 补齐：link + payload 落库，再走一次真实 load()（它会在开头
        //    `resolveBackdropSource()` 重读 overlay）。注意 payload 的新鲜度足以让
        //    `refresh` 走 `.skipped`，因此这条路径**不发网络**。
        try await store.saveTMDbLink(itemID: "s-1", entityKey: .tv(71785),
                                     source: .providerID, confidence: 1.0, tenant: tenant)
        try await store.saveTMDbPayload(
            .entity(TMDbEntity(id: 71785, mediaType: .tv, title: "TMDB 标题",
                               backdropPath: "/3UbHGmu9vIMSC5uNfnGt7DjetqT.jpg")),
            key: .tv(71785), language: "zh-CN", lifetime: 3600)
        stub.itemResult = .success(landed)
        await model.load()

        // 控制断言：overlay 真的到了，且现算规则**会**改口成 TMDB 图。
        let overlay = try XCTUnwrap(model.tmdbOverlay, "overlay 没到，本用例就没有判别力")
        XCTAssertEqual(overlay.backdropPath, "/3UbHGmu9vIMSC5uNfnGt7DjetqT.jpg")
        let serverURL = landed.imageTarget(app.server, kind: .backdrop, width: 800).url
        let unlockedRule = DisplayMetadata.backdropURL(
            serverURL: serverURL, overlay: overlay, requestedWidth: 800,
            policy: app.tmdbImagePolicy)
        XCTAssertNotEqual(unlockedRule?.absoluteString, lockedURL.absoluteString,
                          "现算规则此刻确实会改口成 TMDB 图——否则「锁定」无从谈起")
        XCTAssertEqual(DisplayMetadata.isTMDbImage(unlockedRule), true)

        // 4) 判据：已锁的档不改口，且不串凭证。
        let afterURL = try XCTUnwrap(model.backdropTarget(width: 800).url)
        XCTAssertEqual(afterURL, lockedURL,
                       "迟到的 TMDB overlay 不许顶掉已锁的服务端图（这就是用户看到的闪图）")
        XCTAssertFalse(afterURL.absoluteString.contains("3UbHGmu9vIMSC5uNfnGt7DjetqT"),
                       "更具体的判据：这一档不许变成 TMDB 那张 key art")
        XCTAssertEqual(model.backdropTarget(width: 800).authHeader, stub.authorizationHeader,
                       "凭证必须跟锁定的图同源：仍是服务端图，就仍带服务端 token")
    }

    // MARK: - 宽度档独立

    /// 800（氛围/模糊档）与 1600（清晰档）是两个不同的 URL，锁槽不能共用。
    /// 单槽位会表现为「清晰层被模糊层的 URL 顶替」——不是闪图，但一样是错图。
    func testBackdropLockKeepsWidthBucketsIndependent() async throws {
        let (app, stub, _) = try await makeApp()
        let item = MediaItem(id: "m-1", name: "电影", kind: .movie,
                             backdropImageTag: "server-bd")
        let model = DetailViewModel(item: item)
        model.attach(app)
        await model.resolveBackdropSource()

        let expectedBlur = try XCTUnwrap(item.imageTarget(app.server, kind: .backdrop, width: 800).url)
        let expectedSharp = try XCTUnwrap(item.imageTarget(app.server, kind: .backdrop, width: 1600).url)
        XCTAssertNotEqual(expectedBlur, expectedSharp, "前提：两个宽度档本来就是两个 URL")

        let blur = try XCTUnwrap(model.backdropTarget(width: 800).url)
        let sharp = try XCTUnwrap(model.backdropTarget(width: 1600).url)
        XCTAssertEqual(blur, expectedBlur, "氛围档取 800")
        XCTAssertEqual(sharp, expectedSharp, "清晰档必须是 1600 那张，不能被 800 档的锁顶替")

        XCTAssertEqual(model.backdropTarget(width: 800).authHeader, stub.authorizationHeader)
        XCTAssertEqual(model.backdropTarget(width: 1600).authHeader, stub.authorizationHeader)
    }

    // MARK: - 观测钩子本身的契约

    /// `onApplyDetailContent` 是别人写顺序断言的观测点。钩子若**从不被调用**，
    /// 依赖它的断言会静默空跑（闭包不执行 = 断言不执行 = 假绿）。
    /// 所以钩子自身要有契约用例：真的会响，且响在 `applyDetailContent` 的**第一行**。
    func testApplyDetailContentHookFiresBeforeContentLands() async throws {
        let (app, stub, _) = try await makeApp(configureKey: false)
        let listItem = MediaItem(id: "m-1", name: "电影", kind: .movie)
        let landed = MediaItem(id: "m-1", name: "电影", kind: .movie,
                               backdropImageTag: "server-bd")
        stub.itemResult = .success(landed)

        let model = DetailViewModel(item: listItem)
        model.attach(app)

        var calls = 0
        var resolvedAtFirstCall: Bool?
        var detailTagAtFirstCall: String?
        model.onApplyDetailContent = {
            calls += 1
            guard calls == 1 else { return }
            resolvedAtFirstCall = model.isBackdropSourceResolved
            detailTagAtFirstCall = model.detail?.backdropImageTag
        }

        await model.load()

        XCTAssertGreaterThanOrEqual(calls, 1, "钩子必须真的被调用，否则依赖它的顺序断言全是空跑")
        XCTAssertEqual(resolvedAtFirstCall, true,
                       "内容上屏那一刻，背景来源必须已经解析完（顺序本身就是修复的一部分）")
        XCTAssertNil(detailTagAtFirstCall,
                     "钩子位于第一行：此刻 detail 还没被本次内容改写，否则它看到的不是「上屏前」")
    }
}
