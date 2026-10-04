import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// `TMDbCoordinator`：设置读写、按 key 禁用、装配、清数据。
///
/// 这一层是 App 与 `MetadataKit` 的接线，**没测就等于没接**：包内 82 个用例全绿
/// 也可能因为这里少传一个 store、或把设置写错了 defaults 域而完全失效。
///
/// 全部用独立 `UserDefaults(suiteName:)`：`.standard` 在测试宿主里是**真的**
/// 用户域（且并行测试进程共用一个 bundle id），写进去会污染真实设置、也会让
/// 其它用例随机失败——`HomeRailLoadingTests` 那次就是这么被搞挂的。
@MainActor
final class TMDbCoordinatorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "TMDbCoordinatorTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TMDbCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// 走**公开**入口 `MetadataCache.open`（与生产同一条路），
    /// 而不是测试专用的建库工厂。
    private func makeStore() throws -> MetadataStore {
        try MetadataCache.open(at: directory)
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    // MARK: - 未配置 = 禁用

    /// 没 key 时：`isConfigured` 为假、`isReady` 为假、所有补全方法静默无操作。
    func testDisabledWithoutKey() async throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertFalse(coordinator.isReady)
        XCTAssertEqual(coordinator.apiKeyDisplay, "未配置")

        coordinator.attach(store: try makeStore())
        let movie = MediaItem(id: "m1", name: "某片", kind: .movie, tmdbID: "603")

        let overlay = await coordinator.overlay(for: movie, tenant: tenant)
        XCTAssertNil(overlay, "未配置时不该有叠加数据")
        let didFetch = await coordinator.refresh(item: movie, tenant: tenant)
        XCTAssertFalse(didFetch, "未配置时不该发请求")
    }

    // MARK: - 设置读写与持久化

    func testKeyRoundTripsAndEnables() throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")

        XCTAssertTrue(coordinator.isConfigured)
        // 回显只给尾部 4 位：完整 key 出现在截图/肩窥里没有好处
        XCTAssertEqual(coordinator.apiKeyDisplay, "••••cdef")
        XCTAssertFalse(coordinator.apiKeyDisplay.contains("0123456789"))

        // 换一个实例（模拟重启）：设置要还在
        let reopened = TMDbCoordinator(defaults: defaults)
        XCTAssertTrue(reopened.isConfigured, "key 应持久化")
        XCTAssertEqual(reopened.apiKeyDisplay, "••••cdef")
    }

    /// 前后空白与纯空白都当「没填」——用户从网页复制常带换行。
    func testWhitespaceOnlyKeyIsTreatedAsEmpty() throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("  \n  ")
        XCTAssertFalse(coordinator.isConfigured)

        coordinator.setAPIKey("  abc123  ")
        XCTAssertTrue(coordinator.isConfigured)
        XCTAssertEqual(coordinator.apiKeyDisplay, "••••c123", "前后空白应被剥掉")
    }

    /// 清掉 key = 停用（留空即禁用的模型，不需要第二个开关）。
    func testClearingKeyDisables() throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("abc")
        XCTAssertTrue(coordinator.isConfigured)

        coordinator.setAPIKey(nil)
        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertEqual(coordinator.apiKeyDisplay, "未配置")
        XCTAssertNil(TMDbCoordinator(defaults: defaults).apiKeyDisplay == "••••abc" ? "x" : nil)
    }

    func testLanguageAndTogglesPersist() throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setLanguage("en-US")
        coordinator.setPreferText(false)
        coordinator.setReplaceImages(true)

        let reopened = TMDbCoordinator(defaults: defaults)
        XCTAssertEqual(reopened.language, "en-US")
        XCTAssertFalse(reopened.preferText)
        XCTAssertTrue(reopened.replaceImages)
    }

    /// 默认值：`zh-CN` + **文本与图片都 TMDb 优先** + 90 天缓存。
    ///
    /// 两个「默认开」的开关尤其要钉住：它们都用 `object(forKey:)` 判存在而不是
    /// `bool(forKey:)`——后者对默认开的开关在键不存在时返回 false，
    /// 会让默认值静默失效。
    ///
    /// 图片默认也从「只补缺」改成了「TMDb 优先」（用户口径：填了 key 就是想要
    /// 完整补全，能用 TMDb 就用），所以这里断言为 true。
    func testDefaults() {
        let coordinator = TMDbCoordinator(defaults: defaults)
        XCTAssertEqual(coordinator.language, "zh-CN")
        XCTAssertTrue(coordinator.preferText)
        XCTAssertTrue(coordinator.replaceImages, "默认 TMDb 优先")
        XCTAssertEqual(coordinator.cacheDays, TMDbPreferences.defaultCacheDays)
    }

    /// 但用户**显式关掉**后必须尊重（默认开不等于强制开）。
    func testImageReplacementCanBeTurnedOff() throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setReplaceImages(false)
        XCTAssertFalse(coordinator.replaceImages)
        // 换实例（模拟重启）后仍是关
        XCTAssertFalse(TMDbCoordinator(defaults: defaults).replaceImages)
        XCTAssertFalse(TMDbImagePolicy(replacesExisting: coordinator.replaceImages).replacesExisting)
    }

    /// 缓存天数被夹在 TMDb 条款上限内（6 个月），且下限为 1 天。
    func testCacheDaysIsClamped() {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setCacheDays(9999)
        XCTAssertEqual(coordinator.cacheDays, TMDbPreferences.maxCacheDays)
        XCTAssertEqual(coordinator.maxCacheDays, 180, "条款上限是 6 个月，不要调大")

        coordinator.setCacheDays(0)
        XCTAssertEqual(coordinator.cacheDays, 1)
    }

    /// 图片策略直接反映设置开关（详情页每次现读它，所以改了立刻生效）。
    func testImagePolicyFollowsSetting() {
        let coordinator = TMDbCoordinator(defaults: defaults)
        XCTAssertTrue(TMDbImagePolicy(replacesExisting: coordinator.replaceImages).replacesExisting,
                      "默认 TMDb 优先")
        coordinator.setReplaceImages(false)
        XCTAssertFalse(TMDbImagePolicy(replacesExisting: coordinator.replaceImages).replacesExisting)
    }

    /// 换语言会清掉「已补全」计数：旧语言的计数不再准确，新语言的数据要重拉。
    func testChangingLanguageResetsCount() async throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")
        coordinator.attach(store: try makeStore())

        // 先手工造一条对应，让计数为 1
        let store = try makeStore()
        try await store.saveTMDbLink(itemID: "m1", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenant)
        await coordinator.refreshLinkedCount(tenant: tenant)
        XCTAssertEqual(coordinator.linkedCount, 1)

        coordinator.setLanguage("en-US")
        XCTAssertEqual(coordinator.linkedCount, 0, "换语言后计数要重算")
    }

    // MARK: - 装配与清数据

    /// 清数据：对应关系与孤儿实体一起走（用户点「清除」不该留下查不到的死数据）。
    func testClearRemovesLinksAndEntities() async throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")
        let store = try makeStore()
        coordinator.attach(store: store)

        try await store.saveTMDbPayload(.entity(TMDbEntity(id: 603, mediaType: .movie)),
                                       key: .movie(603), language: "zh-CN", lifetime: 3600)
        try await store.saveTMDbLink(itemID: "m1", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenant)
        await coordinator.refreshLinkedCount(tenant: tenant)
        XCTAssertEqual(coordinator.linkedCount, 1)

        await coordinator.clear(tenant: tenant)

        XCTAssertEqual(coordinator.linkedCount, 0)
        let link = try await store.linkedTMDbEntity(itemID: "m1", tenant: tenant)
        XCTAssertNil(link)
        let payload = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertNil(payload, "没人引用的实体也该被清掉")
    }

    /// `attach(nil)`（建库还没完成）不该崩，也不该把已装配的服务弄坏。
    func testAttachNilStoreIsHarmless() async throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")
        coordinator.attach(store: nil)
        XCTAssertFalse(coordinator.isReady, "没 store 时不算就绪")

        // 之后再补上就能用
        coordinator.attach(store: try makeStore())
        XCTAssertTrue(coordinator.isReady)
    }

    func testRefreshLinkedCountWithoutTenantIsZero() async throws {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")
        coordinator.attach(store: try makeStore())
        await coordinator.refreshLinkedCount(tenant: nil)
        XCTAssertEqual(coordinator.linkedCount, 0)
    }

    // MARK: - 失败可见（坏 key 不再静默）

    /// 每种失败都要有**用户能看懂**的文案；两种「不该打扰用户」的必须静默。
    ///
    /// 这条路径原先完全静默：用户填了 key、翻了几页、什么都没发生，只会以为
    /// 功能坏了。实测（把 key 换成无效值后开详情页）确认设置页会显示
    /// 「API Key 无效或已被 TMDb 拒绝」。
    func testFailureMessages() {
        XCTAssertEqual(TMDbCoordinator.message(for: .unauthorized), "API Key 无效或已被 TMDb 拒绝")
        XCTAssertEqual(TMDbCoordinator.message(for: .transport("x")), "连不上 TMDb（检查网络或代理）")
        XCTAssertEqual(TMDbCoordinator.message(for: .rateLimited(retryAfter: 5)), "TMDb 限流，请稍后再试")
        XCTAssertEqual(TMDbCoordinator.message(for: .http(status: 503)), "TMDb 返回 HTTP 503")
        XCTAssertEqual(TMDbCoordinator.message(for: .decoding("x")), "TMDb 返回了无法解析的数据")
        // 成功 → 不提示
        XCTAssertNil(TMDbCoordinator.message(for: nil))
        // 未配置 key 是「功能关着」，不是错误
        XCTAssertNil(TMDbCoordinator.message(for: .notConfigured))
        // 脏 ProviderIds（id 在 TMDb 不存在）：用户无法处理，不打扰
        XCTAssertNil(TMDbCoordinator.message(for: .notFound))
    }

    /// 每个错误都必须有文案或**明确**静默——不能出现「漏掉一个 case」导致
    /// 用户什么都看不到（用穷举断言钉住）。
    func testEveryErrorIsHandled() {
        let all: [TMDbError] = [.notConfigured, .unauthorized, .rateLimited(retryAfter: nil),
                                .notFound, .http(status: 500), .transport("x"), .decoding("x")]
        for error in all {
            let message = TMDbCoordinator.message(for: error)
            switch error {
            case .notConfigured, .notFound:
                XCTAssertNil(message, "\(error) 应静默")
            default:
                XCTAssertNotNil(message, "\(error) 必须有可读文案")
                XCTAssertFalse(message!.isEmpty)
            }
        }
    }

    // MARK: - AppModel 接线

    /// `AppModel` 默认用注入的 `preferences` 域构造 TMDb 协调器——
    /// 否则测试传了独立 suite，TMDb 的设置仍会写进真实的 `.standard`。
    func testAppModelUsesInjectedPreferencesDomain() async throws {
        let app = AppModel(preferences: defaults)
        app.tmdb.setAPIKey("0123456789abcdef0123456789abcdef")
        // 写在注入域里，而不是 .standard
        XCTAssertNotNil(defaults.string(forKey: TMDbCredentialStore.defaultsKey))
    }

    /// `currentTenant` 现算：没有会话时为 nil（不该读上一台的缓存）。
    func testCurrentTenantIsNilWithoutSession() {
        let app = AppModel(preferences: defaults)
        XCTAssertNil(app.currentTenant)
    }

    /// 图片策略跟着设置走（详情页取图时现读）。
    func testAppModelImagePolicyReflectsSetting() {
        let app = AppModel(preferences: defaults)
        XCTAssertTrue(app.tmdbImagePolicy.replacesExisting, "默认 TMDb 优先")
        app.tmdb.setReplaceImages(false)
        XCTAssertFalse(app.tmdbImagePolicy.replacesExisting)
    }
}
