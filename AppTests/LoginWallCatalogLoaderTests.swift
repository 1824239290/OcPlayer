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
                forKey: "dev.jumusu.ocplayer.imageCacheIdentity." + tenant)
        }

        XCTAssertNil(ImageCacheIdentityStore.identity(for: tenant), "没记过就该是 nil")

        ImageCacheIdentityStore.remember(identity: "abcdef123456", tenant: tenant)
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: tenant), "abcdef123456")
    }

    /// 空值一律当「没记过」：写入空串不该让登录页以为有身份可用。
    func testIdentityStoreIgnoresEmptyValues() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(
                forKey: "dev.jumusu.ocplayer.imageCacheIdentity." + tenant)
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
            UserDefaults.standard.removeObject(forKey: "dev.jumusu.ocplayer.imageCacheIdentity." + a)
            UserDefaults.standard.removeObject(forKey: "dev.jumusu.ocplayer.imageCacheIdentity." + b)
        }

        ImageCacheIdentityStore.remember(identity: "aaa111aaa111", tenant: a)
        ImageCacheIdentityStore.remember(identity: "bbb222bbb222", tenant: b)

        XCTAssertEqual(ImageCacheIdentityStore.identity(for: a), "aaa111aaa111")
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: b), "bbb222bbb222")
    }

    // MARK: 身份历史（token 轮换）

    /// **记的是一串、最近的在前、同一个不重复**。
    ///
    /// 这条挡的是本机实测踩到的那个坑：只记「上次生效的那一个」，token 一轮换就把它
    /// 覆盖掉，墙上 47 张海报一张都查不到（字节全在磁盘上）。
    func testIdentityHistoryKeepsMostRecentFirstWithoutDuplicates() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        let key = "dev.jumusu.ocplayer.imageCacheIdentity." + tenant
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        ImageCacheIdentityStore.remember(identity: "aaa111aaa111", tenant: tenant)
        ImageCacheIdentityStore.remember(identity: "bbb222bbb222", tenant: tenant)
        // 回到旧身份：应当被提到最前，而不是出现两次。
        ImageCacheIdentityStore.remember(identity: "aaa111aaa111", tenant: tenant)

        XCTAssertEqual(
            ImageCacheIdentityStore.history(for: tenant),
            ["aaa111aaa111", "bbb222bbb222"]
        )
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: tenant), "aaa111aaa111")
    }

    /// 历史有上界，不会无限增长。
    func testIdentityHistoryIsCapped() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        let key = "dev.jumusu.ocplayer.imageCacheIdentity." + tenant
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        for index in 0..<(ImageCacheIdentityStore.historyLimit + 5) {
            ImageCacheIdentityStore.remember(identity: String(format: "%012x", index), tenant: tenant)
        }

        let history = ImageCacheIdentityStore.history(for: tenant)
        XCTAssertEqual(history.count, ImageCacheIdentityStore.historyLimit)
        // 最新的那个必须在，最老的那些被挤掉。
        XCTAssertEqual(history.first, String(format: "%012x", ImageCacheIdentityStore.historyLimit + 4))
    }

    /// 旧版在这个键上存的是**一个字符串**，新版存数组。旧值必须能平滑升上来
    /// ——否则升级一次就等于「所有人重新变回程序化封面」。
    func testLegacySingleStringValueIsReadAsHistory() {
        let tenant = "test-tenant-\(UUID().uuidString)"
        let key = "dev.jumusu.ocplayer.imageCacheIdentity." + tenant
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.set("legacy123456", forKey: key)

        XCTAssertEqual(ImageCacheIdentityStore.history(for: tenant), ["legacy123456"])
        XCTAssertEqual(ImageCacheIdentityStore.identity(for: tenant), "legacy123456")
    }

    // MARK: 从 URL 缓存里捞历史身份

    /// `URLCache` 的键就是那条带 `_auth=<身份>` 的规范化 URL，所以字节里能捞出
    /// 「这批图当初是用哪个身份写进去的」。这是丢掉的历史身份**唯一**的现存记录。
    func testAuthIdentitiesAreExtractedFromRawBytes() {
        let raw = Data("""
        <key>http://ocplayer.invalid/Items/abc/Images/Primary?maxWidth=400&tag=ff&_auth=b484f14daf8d</key>
        <key>http://ocplayer.invalid/Items/def/Images/Primary?maxWidth=300&tag=aa&_auth=ceb97745c31d</key>
        """.utf8)

        XCTAssertEqual(
            ImageCacheIdentityStore.authIdentities(in: raw),
            ["b484f14daf8d", "ceb97745c31d"]
        )
    }

    /// 非身份的 `_auth=` 值（公开图床写的 `none`）与畸形值都不能被当成身份——
    /// 混进去只是白白多几次查文件，但那说明解析是错的。
    func testAuthIdentitiesIgnoresNonIdentityValues() {
        let raw = Data("_auth=none _auth=SHORT _auth=ABCDEFABCDEF _auth=  _auth=12345g789012".utf8)
        XCTAssertTrue(
            ImageCacheIdentityStore.authIdentities(in: raw).isEmpty,
            "捞出了非身份值：\(ImageCacheIdentityStore.authIdentities(in: raw))"
        )
    }

    /// 扫描**必须如实报告「被取消」**，不能把「没扫完」混成「扫完了但没找到」。
    func testScanSeparatesCancellationFromEmptyResult() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try? Data("_auth=b484f14daf8d".utf8)
            .write(to: dir.appendingPathComponent("Cache.db"))

        // 未取消：wasCancelled 必须是 false（空结果 ≠ 被取消）。
        let clean = await ImageCacheIdentityStore.scanURLCacheForIdentities(in: dir)
        XCTAssertFalse(clean.wasCancelled, "正常扫完时不能报成被取消")

        // 在已取消的任务里跑：必须报 wasCancelled，而不是安静地返回空集。
        let task = Task {
            await ImageCacheIdentityStore.scanURLCacheForIdentities(in: dir)
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.wasCancelled, "任务已取消时扫描必须如实报告")
    }

    /// **取消之后必须能重扫、并把身份捞回来。**
    ///
    /// 这条才是 `9fd4dbd` 修复语义的真正守门人：前一条只断言了 `scanURLCache`
    /// 的返回值，**没有断言 `didScanURLCache` 被复位**。审查用变异证明过——
    /// 把 `discoveredIdentities` 里 `guard !scan.wasCancelled` 那段删掉（行为退回
    /// 修复前），前一条用例照样全绿，而身份池仍被**永久截断**。
    ///
    /// 所以这里走**完整入口** `identities(for:in:)`（不是扫描函数本身）：
    /// ① 先在被取消的任务里触发一次扫描 → 只有部分结果、标志应复位；
    /// ② 再正常调一次 → 必须真的把 Cache.db 里的 `_auth=` 身份捞进结果。
    /// 修复前 ② 拿不到任何捞回身份（因为 `didScanURLCache` 已置位、直接短路）。
    func testCancelledScanIsRetriedAndRecoversIdentities() async throws {
        let tenant = "tenant-\(UUID().uuidString)"
        let discoveredKey = "dev.jumusu.ocplayer.imageCacheIdentities.discovered"
        let historyKey = "dev.jumusu.ocplayer.imageCacheIdentity." + tenant
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: historyKey)
            UserDefaults.standard.removeObject(forKey: discoveredKey)
        }
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: discoveredKey)
        ImageCacheIdentityStore.resetDiscoveredScanForTesting()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // 目标身份：必须是小写十六进制 12 位。
        let target = "b484f14daf8d"
        try Data("_auth=\(target)".utf8)
            .write(to: dir.appendingPathComponent("Cache.db"))

        // ① 在被取消的任务里扫一次。`Task.cancel()` 在任务开跑前置位，
        //    扫描函数一进循环就应当看到取消。
        let cancelledTask = Task {
            await ImageCacheIdentityStore.identities(for: tenant, in: dir)
        }
        cancelledTask.cancel()
        _ = await cancelledTask.value

        // ② 正常再扫一次：必须能捞出目标身份。
        ImageCacheIdentityStore.resetDiscoveredScanForTesting()
        let identities = await ImageCacheIdentityStore.identities(for: tenant, in: dir)
        XCTAssertTrue(
            identities.contains(target),
            "取消后重扫必须捞回身份（修复前这里会因「已扫过」标志短路而永远为空）：\(identities)"
        )
    }

    /// 没有任何 `_auth=` 时安静返回空集，不崩。
    func testAuthIdentitiesHandlesEmptyAndUnrelatedBytes() {
        XCTAssertTrue(ImageCacheIdentityStore.authIdentities(in: Data()).isEmpty)
        XCTAssertTrue(ImageCacheIdentityStore.authIdentities(in: Data("hello world".utf8)).isEmpty)
    }
}
