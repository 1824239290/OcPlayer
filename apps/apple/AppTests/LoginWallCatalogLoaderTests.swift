import AppDesignKit
import XCTest

@testable import OcPlayer

/// 登录页海报墙**素材装配**的回归。
///
/// **存在的意义**：墙的素材来源有三条各自会静默失败的路径——元数据缓存、缓存身份、
/// 图片缓存键——任何一条断了，墙都只是**变空**或**退成程序化封面**，不报错。真机上
/// 看起来像「设计就是这样」。所以这里把「什么时候该退兜底」与「兜底本身确定不确定」
/// 钉住；键的复原由 `AppDesignKit` 的 `ImagePipelinePosterLookupTests` 覆盖。
@MainActor
final class LoginWallCatalogLoaderTests: XCTestCase {

    // MARK: 兜底

    /// 首次安装 / 没有元数据缓存 / 从没记过缓存身份：退到程序化封面。
    /// 墙不能是空的——空墙在登录页上就是一片纯色。
    func testProceduralCatalogIsNeverEmpty() {
        let catalog = LoginWallCatalogLoader.proceduralCatalog(count: LoginWallCatalogLoader.fallbackSize)
        XCTAssertEqual(catalog.count, LoginWallCatalogLoader.fallbackSize)
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertTrue(catalog.allSatisfy { $0.imageFile == nil }, "兜底封面不该指任何缓存文件")
    }

    /// 兜底张数要够铺满**常见窗口里最大的那面墙**（2560×1440 实测 91 张 tile）。
    /// 少了同一张海报会在一屏里出现两次，那是看得出来的。
    func testFallbackIsLargeEnoughForTheLargestCommonWindow() {
        let largest = LoginWallLayout(size: CGSize(width: 2560, height: 1440), catalogSize: 10_000).tileCount
        XCTAssertGreaterThanOrEqual(
            LoginWallCatalogLoader.fallbackSize, largest,
            "兜底张数（\(LoginWallCatalogLoader.fallbackSize)）少于最大常见窗口的 tile 数（\(largest)）时，一屏里会出现重复海报"
        )
        // 真装配路径的目录同样要够，否则大窗口上也会重复。
        XCTAssertGreaterThanOrEqual(LoginWallCatalogLoader.catalogSize, largest)
    }

    /// **确定性**：同样的输入永远同样的封面。用 `Hasher` / `hashValue` 播种会让墙
    /// 每次冷启动都换一副面孔。
    func testProceduralCatalogIsDeterministic() {
        let first = LoginWallCatalogLoader.proceduralCatalog(count: 12)
        let second = LoginWallCatalogLoader.proceduralCatalog(count: 12)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.art), second.map(\.art))
    }

    /// 相邻两张封面不该长得一样，否则墙上会出现一片同色块。
    func testAdjacentArtworkDiffers() {
        let arts = LoginWallCatalogLoader.proceduralCatalog(count: 24).map(\.art)
        XCTAssertEqual(Set(arts).count, arts.count, "出现了重复的程序化封面")
    }

    /// 张数请求收敛到合理范围：0 / 负数不崩，正常值原样。
    func testProceduralCatalogHandlesDegenerateCounts() {
        XCTAssertTrue(LoginWallCatalogLoader.proceduralCatalog(count: 0).isEmpty)
        XCTAssertTrue(LoginWallCatalogLoader.proceduralCatalog(count: -5).isEmpty)
        XCTAssertEqual(LoginWallCatalogLoader.proceduralCatalog(count: 7).count, 7)
    }

    /// 装配出来的条目身份唯一——`ForEach` 靠它，撞了整面墙会渲染错乱。
    func testCatalogIdentitiesAreUnique() {
        let catalog = LoginWallCatalogLoader.proceduralCatalog(count: 40)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
    }

    // MARK: 真装配路径

    /// 元数据库没建起来时（首次冷启动、建库失败）**必须**安静地退兜底，
    /// 而不是返回空墙或抛错。
    func testLoadFallsBackWhenMetadataIsUnavailable() async {
        let app = AppModel()
        let catalog = await LoginWallCatalogLoader.load(app: app)
        XCTAssertFalse(catalog.isEmpty, "没有元数据缓存时应当退到程序化封面，而不是空墙")
        XCTAssertTrue(catalog.allSatisfy { $0.imageFile == nil })
    }

    /// 真装配路径**不发网络请求**：它只读元数据库 + 图片缓存目录。
    /// 这条是「登录页完全离线可用」的守门人。
    func testLibraryPostersIsEmptyWithoutCacheIdentity() async {
        let app = AppModel()
        let posters = await LoginWallCatalogLoader.libraryPosters(app: app)
        XCTAssertTrue(posters.isEmpty, "没记过缓存身份时应当拿不出任何条目海报")
    }

    // MARK: 缓存身份

    /// 身份**跨实例可读**（登录页总是冷启动后的第一屏），且登出时**刻意不清**
    /// ——清掉就等于把「登录页该显示什么」一起清掉了。
    func testIdentityStoreRoundTrip() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(
                forKey: "dev.jumusu.ocplayer.imageCacheIdentity.v2." + tenant)
        }

        XCTAssertNil(ImageCacheIdentityStore.identity(for: tenant), "没记过就该是 nil")

        ImageCacheIdentityStore.remember(identity: "v2-scope-abcdef123456", tenant: tenant)
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: tenant), "v2-scope-abcdef123456")
    }

    /// 空值一律当「没记过」：写入空串不该让登录页以为有身份可用。
    func testIdentityStoreIgnoresEmptyValues() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(
                forKey: "dev.jumusu.ocplayer.imageCacheIdentity.v2." + tenant)
        }

        ImageCacheIdentityStore.remember(identity: "", tenant: tenant)
        XCTAssertNil(ImageCacheIdentityStore.identity(for: tenant))

        ImageCacheIdentityStore.remember(identity: "abc", tenant: "")
        XCTAssertNil(ImageCacheIdentityStore.identity(for: ""))
    }

    /// 两台服务器各自记各自的身份，互不覆盖。
    func testIdentityStoreIsPerTenant() {
        let a = "tenant-a-\(UUID().uuidString)"
        let b = "tenant-b-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "dev.jumusu.ocplayer.imageCacheIdentity.v2." + a)
            UserDefaults.standard.removeObject(forKey: "dev.jumusu.ocplayer.imageCacheIdentity.v2." + b)
        }

        ImageCacheIdentityStore.remember(identity: "v2-scope-aaa111aaa111", tenant: a)
        ImageCacheIdentityStore.remember(identity: "v2-scope-bbb222bbb222", tenant: b)

        XCTAssertEqual(ImageCacheIdentityStore.identity(for: a), "v2-scope-aaa111aaa111")
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: b), "v2-scope-bbb222bbb222")
    }

    // MARK: 身份历史（token 轮换）

    /// **记的是一串、最近的在前、同一个不重复**。
    ///
    /// 这条挡的是本机实测踩到的那个坑：只记「上次生效的那一个」，token 一轮换就把它
    /// 覆盖掉，墙上 47 张海报一张都查不到（字节全在磁盘上）。
    func testIdentityHistoryKeepsMostRecentFirstWithoutDuplicates() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        let key = "dev.jumusu.ocplayer.imageCacheIdentity.v2." + tenant
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        ImageCacheIdentityStore.remember(identity: "v2-scope-aaa111aaa111", tenant: tenant)
        ImageCacheIdentityStore.remember(identity: "v2-scope-bbb222bbb222", tenant: tenant)
        // 回到旧身份：应当被提到最前，而不是出现两次。
        ImageCacheIdentityStore.remember(identity: "v2-scope-aaa111aaa111", tenant: tenant)

        XCTAssertEqual(
            ImageCacheIdentityStore.history(for: tenant),
            ["v2-scope-aaa111aaa111", "v2-scope-bbb222bbb222"]
        )
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: tenant), "v2-scope-aaa111aaa111")
    }

    /// 历史有上界，不会无限增长。
    func testIdentityHistoryIsCapped() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        let key = "dev.jumusu.ocplayer.imageCacheIdentity.v2." + tenant
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        for index in 0..<(ImageCacheIdentityStore.historyLimit + 5) {
            ImageCacheIdentityStore.remember(identity: "v2-scope-" + String(format: "%012x", index), tenant: tenant)
        }

        let history = ImageCacheIdentityStore.history(for: tenant)
        XCTAssertEqual(history.count, ImageCacheIdentityStore.historyLimit)
        // 最新的那个必须在，最老的那些被挤掉。
        XCTAssertEqual(history.first, "v2-scope-" + String(format: "%012x", ImageCacheIdentityStore.historyLimit + 4))
    }

    /// v1 只有账号身份；即使曾记在这个档案下，也无法排除已串服的缓存。
    func testLegacyHistoryAndGlobalDiscoveryAreNotRecovered() async {
        let tenant = "migration-\(UUID().uuidString)"
        let oldKey = "dev.jumusu.ocplayer.imageCacheIdentity." + tenant
        let globalKey = "dev.jumusu.ocplayer.imageCacheIdentities.discovered"
        let originalGlobal = UserDefaults.standard.object(forKey: globalKey)
        defer {
            UserDefaults.standard.removeObject(forKey: oldKey)
            if let originalGlobal { UserDefaults.standard.set(originalGlobal, forKey: globalKey) }
            else { UserDefaults.standard.removeObject(forKey: globalKey) }
            UserDefaults.standard.removeObject(forKey: ImageCacheIdentityStore.prefix + tenant)
        }
        UserDefaults.standard.set(["abcdef123456"], forKey: oldKey)
        UserDefaults.standard.set(["v2-other-server-abcdef123456"], forKey: globalKey)
        let oldIdentities = await ImageCacheIdentityStore.identities(for: tenant)
        XCTAssertTrue(oldIdentities.isEmpty)
        ImageCacheIdentityStore.remember(identity: "v2-current-123456abcdef", tenant: tenant)
        let newIdentities = await ImageCacheIdentityStore.identities(for: tenant)
        XCTAssertEqual(newIdentities, ["v2-current-123456abcdef"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: oldKey), ["abcdef123456"], "迁移边界不删除旧记录")
    }

    func testUnscopedIdentityCannotBeRememberedOrRestored() async {
        let tenant = "unscoped-\(UUID().uuidString)"
        let key = ImageCacheIdentityStore.prefix + tenant
        defer { UserDefaults.standard.removeObject(forKey: key) }
        ImageCacheIdentityStore.remember(identity: "abcdef123456", tenant: tenant)
        XCTAssertNil(ImageCacheIdentityStore.identity(for: tenant))
        UserDefaults.standard.set(["abcdef123456", "v2-current-123456abcdef"], forKey: key)
        let identities = await ImageCacheIdentityStore.identities(for: tenant)
        XCTAssertEqual(identities, ["v2-current-123456abcdef"])
    }
}
