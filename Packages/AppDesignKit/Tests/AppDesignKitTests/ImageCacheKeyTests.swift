import Foundation
import XCTest

@testable import AppDesignKit

/// 图片缓存键规范化。
///
/// 钉住的核心行为：**同一台服务器的两条入口共用一份缓存**。修复前键是完整 URL
/// （含 host），局域网与 Tailscale 各存一份、换地址后每张海报重下一遍——
/// 而「多条地址自动择优」正是这个 App 明确支持的能力。
final class ImageCacheKeyTests: XCTestCase {

    private func mediaURL(host: String, item: String = "abc123", width: Int = 720,
                          tag: String = "deadbeef") -> URL {
        URL(string: "http://\(host):8096/Items/\(item)/Images/Thumb?maxWidth=\(width)&tag=\(tag)")!
    }

    // MARK: - 核心：换地址共键

    /// 同一路径、**不同 host** → 同一个规范化键（这就是本修复的全部目的）。
    func testSamePathOnDifferentHostsSharesKey() {
        let lan = ImageCacheKey.canonicalURL(for: mediaURL(host: "192.168.5.107"), authHeader: "Tok=\"a\"")
        let wan = ImageCacheKey.canonicalURL(for: mediaURL(host: "100.127.128.96"), authHeader: "Tok=\"a\"")
        let reverse = ImageCacheKey.canonicalURL(for: mediaURL(host: "nas.example.com"), authHeader: "Tok=\"a\"")

        XCTAssertNotNil(lan)
        XCTAssertEqual(lan, wan, "局域网与 Tailscale 必须共键")
        XCTAssertEqual(lan, reverse, "反代域名也必须共键")
    }

    /// 规范化后 host 被换成占位符，**原地址不再出现在键里**。
    func testCanonicalKeyDropsOriginalHost() throws {
        let key = try XCTUnwrap(
            ImageCacheKey.canonicalURL(for: mediaURL(host: "192.168.5.107"), authHeader: nil))
        XCTAssertEqual(key.host, ImageCacheKey.placeholderHost)
        XCTAssertFalse(key.absoluteString.contains("192.168.5.107"))
        // 路径与查询原样保留（否则会串图）
        XCTAssertEqual(key.path, "/Items/abc123/Images/Thumb")
        XCTAssertTrue(key.query?.contains("maxWidth=720") == true)
        XCTAssertTrue(key.query?.contains("tag=deadbeef") == true)
    }

    // MARK: - 不该共键的

    /// 不同条目 / 不同尺寸 / 不同 tag → 不同键（串图就是灾难）。
    func testDistinctImagesKeepDistinctKeys() {
        let base = ImageCacheKey.canonicalURL(for: mediaURL(host: "h"), authHeader: "A")
        let otherItem = ImageCacheKey.canonicalURL(for: mediaURL(host: "h", item: "zzz"), authHeader: "A")
        let otherWidth = ImageCacheKey.canonicalURL(for: mediaURL(host: "h", width: 400), authHeader: "A")
        let otherTag = ImageCacheKey.canonicalURL(for: mediaURL(host: "h", tag: "cafe"), authHeader: "A")

        XCTAssertNotEqual(base, otherItem)
        XCTAssertNotEqual(base, otherWidth)
        XCTAssertNotEqual(base, otherTag, "服务端换图 → tag 变 → 必须换键（缓存失效）")
    }

    /// **不同服务器 / 不同账号 → 不同键**：丢掉 host 后，认证头是唯一的归属信号。
    func testDifferentAccountsDoNotShareKey() {
        let a = ImageCacheKey.canonicalURL(for: mediaURL(host: "h"), authHeader: "Token=\"userA\"")
        let b = ImageCacheKey.canonicalURL(for: mediaURL(host: "h"), authHeader: "Token=\"userB\"")
        XCTAssertNotEqual(a, b, "同一台服务器上的两个账号不能互看缓存")
        // 但没有认证头时是确定性的（公开图床 / 未登录）
        XCTAssertEqual(
            ImageCacheKey.canonicalURL(for: mediaURL(host: "h"), authHeader: nil),
            ImageCacheKey.canonicalURL(for: mediaURL(host: "h"), authHeader: ""))
    }

    /// 非媒体服务器图床（MoviePilot 海报、bgm 封面）不改键——它们只有一条地址，
    /// 没有这个问题；不动它们可避免「不同图床路径相同」这种理论撞键。
    func testNonServerImageURLsAreLeftAlone() {
        let tmdb = URL(string: "https://image.tmdb.org/t/p/w500/xk.jpg")!
        let bgm = URL(string: "https://lain.bgm.tv/pic/user/l/icon.jpg")!
        XCTAssertNil(ImageCacheKey.canonicalURL(for: tmdb, authHeader: nil))
        XCTAssertNil(ImageCacheKey.canonicalURL(for: bgm, authHeader: nil))
        XCTAssertFalse(ImageCacheKey.isMediaServerImage(tmdb))
        XCTAssertTrue(ImageCacheKey.isMediaServerImage(mediaURL(host: "h")))
    }

    // MARK: - 跨进程稳定

    /// **哈希必须跨进程稳定**：这是磁盘键，用 `String.hashValue`（每进程随机播种）
    /// 会导致每次启动全部缓存失效。这里直接钉住具体值——它变了就意味着
    /// 所有用户的图片缓存会集体失效一次。
    func testAuthIdentityIsStableAcrossProcesses() {
        XCTAssertEqual(ImageCacheKey.authIdentity("Token=\"abc\""), "cf465eb6b7bc")
        XCTAssertEqual(ImageCacheKey.authIdentity(nil), "none")
        XCTAssertEqual(ImageCacheKey.authIdentity(""), "none")
        // 固定长度，便于阅读
        XCTAssertEqual(ImageCacheKey.authIdentity("Token=\"abc\"").count, 12)
    }

    // MARK: - 版本无关（防「每次发版丢缓存」）

    /// **认证头里含 App 版本（构建号 = git 提交数），绝不能进缓存键**。
    /// 实测 Build 505 与 506 的整头哈希不同——用整头哈希当键，等于每次发版把
    /// 用户全部图片缓存作废。
    func testAuthIdentityIgnoresAppVersion() {
        let make = { (version: String) in
            "MediaBrowser Client=\"OcPlayer\", Device=\"mac\", DeviceId=\"DEV-1\", " +
            "Version=\"\(version)\", Token=\"TOK\""
        }
        let v505 = ImageCacheKey.authIdentity(make("0.2.0 (505)"))
        let v506 = ImageCacheKey.authIdentity(make("0.2.0 (506)"))
        let v999 = ImageCacheKey.authIdentity(make("9.9.9 (9999)"))
        XCTAssertEqual(v505, v506, "换版本不该换键")
        XCTAssertEqual(v505, v999)
    }

    /// 换 token / 换设备必须换键（那是另一份可见范围 / 另一次安装）。
    func testAuthIdentityChangesWithTokenAndDevice() {
        func header(device: String, token: String) -> String {
            "MediaBrowser Client=\"OcPlayer\", Device=\"mac\", DeviceId=\"\(device)\", " +
            "Version=\"0.2.0 (506)\", Token=\"\(token)\""
        }
        let base = ImageCacheKey.authIdentity(header(device: "D1", token: "T1"))
        XCTAssertNotEqual(base, ImageCacheKey.authIdentity(header(device: "D1", token: "T2")))
        XCTAssertNotEqual(base, ImageCacheKey.authIdentity(header(device: "D2", token: "T1")))
        XCTAssertEqual(base, ImageCacheKey.authIdentity(header(device: "D1", token: "T1")))
    }

    /// 解析不出来的头（非 Jellyfin/Emby 形态）退回整串哈希，宁可少共享也不误共享。
    func testAuthIdentityFallsBackForUnknownHeaderShape() {
        let weird = ImageCacheKey.authIdentity("Bearer abcdef")
        XCTAssertNotEqual(weird, ImageCacheKey.authIdentity("Bearer xyz"))
        XCTAssertEqual(weird.count, 12)
    }

    // MARK: - 缓存行为（真 URLCache）

    private func makeCache() throws -> CanonicalImageURLCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheKeyTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return CanonicalImageURLCache(memoryCapacity: 0, diskCapacity: 8 * 1024 * 1024, directory: dir)
    }

    private func response(url: URL, body: Data = Data(repeating: 0xAB, count: 128)) -> CachedURLResponse {
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "image/jpeg"])!
        return CachedURLResponse(response: http, data: body)
    }

    private func request(_ url: URL, auth: String? = "Token=\"u\"") -> URLRequest {
        var r = URLRequest(url: url)
        if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        return r
    }

    /// **端到端（真 URLCache）**：从局域网地址存进去，用 Tailscale 地址取出来能命中。
    func testCacheHitAcrossAddresses() throws {
        let cache = try makeCache()
        let lan = mediaURL(host: "192.168.5.107")
        let wan = mediaURL(host: "100.127.128.96")

        cache.storeCachedResponse(response(url: lan), for: request(lan))
        let hit = cache.cachedResponse(for: request(wan))

        XCTAssertNotNil(hit, "换地址后必须命中同一份缓存")
        XCTAssertEqual(hit?.data.count, 128)
        // 返回给上层的响应 URL 应是**本次请求的**地址，不是存进去时的那个
        XCTAssertEqual(hit?.response.url, wan)
        XCTAssertEqual((hit?.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((hit?.response as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String,
                       "image/jpeg")
    }

    /// 不同账号互不命中（隔离性）。
    func testCacheMissForDifferentAccount() throws {
        let cache = try makeCache()
        let url = mediaURL(host: "h")
        cache.storeCachedResponse(response(url: url), for: request(url, auth: "Token=\"A\""))
        XCTAssertNil(cache.cachedResponse(for: request(url, auth: "Token=\"B\"")))
    }

    /// 换 tag 后不命中（服务端换图必须能看到新图）。
    func testCacheMissAfterTagChange() throws {
        let cache = try makeCache()
        let old = mediaURL(host: "h", tag: "old")
        let new = mediaURL(host: "h", tag: "new")
        cache.storeCachedResponse(response(url: old), for: request(old))
        XCTAssertNil(cache.cachedResponse(for: request(new)))
    }

    /// 用户可见的「清空图片缓存」走的是 `removeAllCachedResponses`，它**确实**会让
    /// 查找失效（实测），所以清空按钮是有效的。
    ///
    /// 这里刻意不测 `removeCachedResponse(for:)`（单条删除）：实测本机 Foundation
    /// 上它对磁盘缓存**不可靠**（同一个 URLRequest 对象存完再删，仍然命中），
    /// 断言它等于在测 Foundation 而不是测我们的键。`CanonicalImageURLCache` 仍然
    /// 覆写了那个方法并做规范化——等 Foundation 修好它就是对的；这里只钉住
    /// 「规范化后的键在清空后一定查不到」。
    func testClearAllInvalidatesLookups() throws {
        let cache = try makeCache()
        let lan = mediaURL(host: "192.168.5.107")
        let wan = mediaURL(host: "100.127.128.96")
        cache.storeCachedResponse(response(url: lan), for: request(lan))
        XCTAssertNotNil(cache.cachedResponse(for: request(wan)))

        cache.removeAllCachedResponses()

        // `removeAllCachedResponses` 是**异步**的：实测清空后立刻查仍然命中，
        // 约 1 秒后才真正失效（Foundation 在后头慢慢删盘上的文件）。
        // 轮询而不是死等固定时长，避免在慢机器上偶发失败。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, cache.cachedResponse(for: request(wan)) != nil {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertNil(cache.cachedResponse(for: request(wan)), "清空生效后另一条地址也必须查不到")
        XCTAssertNil(cache.cachedResponse(for: request(lan)))
    }

    /// 非媒体服务器 URL 走原生行为（不被规范化，也就不与新键互串）。
    func testNonServerURLUsesNativeBehaviour() throws {
        let cache = try makeCache()
        let tmdb = URL(string: "https://image.tmdb.org/t/p/w500/xk.jpg")!
        cache.storeCachedResponse(response(url: tmdb), for: request(tmdb, auth: nil))
        XCTAssertNotNil(cache.cachedResponse(for: request(tmdb, auth: nil)))
    }
}

/// 旧键一次性清理。
final class ImageCacheLegacyPurgeTests: XCTestCase {

    func testPurgeRunsOnceOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PurgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let suite = "PurgeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // teardown 闭包里不能捕获 `defaults`（非 Sendable，跨闭包会报数据竞争）——
        // 用名字重建一个来完成清理。
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        let cache = CanonicalImageURLCache(memoryCapacity: 0, diskCapacity: 8 * 1024 * 1024, directory: dir)
        let url = URL(string: "http://h:8096/Items/a/Images/Thumb?maxWidth=720")!
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        cache.storeCachedResponse(CachedURLResponse(response: http, data: Data(repeating: 1, count: 64)),
                                  for: URLRequest(url: url))
        XCTAssertNotNil(cache.cachedResponse(for: URLRequest(url: url)))

        // 第一次：清掉旧键数据
        ImagePipeline.purgeLegacyKeysIfNeeded(cache: cache, defaults: defaults, directory: dir)
        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: url)), "首次应清空")

        // 再存一条，第二次调用**不该**再清（否则每次启动都清空缓存 = 没有缓存）
        cache.storeCachedResponse(CachedURLResponse(response: http, data: Data(repeating: 2, count: 64)),
                                  for: URLRequest(url: url))
        ImagePipeline.purgeLegacyKeysIfNeeded(cache: cache, defaults: defaults, directory: dir)
        XCTAssertNotNil(cache.cachedResponse(for: URLRequest(url: url)), "第二次应跳过，不能再清")
    }
}


/// 自有字节缓存（离线出图的真正依托）。
///
/// 存在的理由见 `ImageBlobStore` 的类型注释：`URLCache` 跨实例读不回来，
/// 实测（条目在库、storage_policy=0、服务器头可缓存，新实例仍 miss），
/// 而「断网重启后海报还在」是用户可见功能，不能建在那种机制上。
final class ImageBlobStoreTests: XCTestCase {

    private func makeStore(maxBytes: Int = 8 * 1024 * 1024) throws -> (ImageBlobStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (ImageBlobStore(directory: dir, maxBytes: maxBytes), dir)
    }

    func testStoreThenReadBack() throws {
        let (store, _) = try makeStore()
        let payload = Data(repeating: 0x7A, count: 4096)
        store.store(payload, forKey: "key-a")
        XCTAssertEqual(store.data(forKey: "key-a"), payload)
        XCTAssertNil(store.data(forKey: "key-b"), "不同键互不串")
    }

    /// **键稳定**：同键两次构造的实例必须互相读得到（模拟「重启 App」）。
    func testSurvivesNewInstance() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStore-persist-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 1, count: 2048)

        ImageBlobStore(directory: dir).store(payload, forKey: "persist")
        // 全新实例（= 重启）应读得到
        XCTAssertEqual(ImageBlobStore(directory: dir).data(forKey: "persist"), payload)
    }

    func testFileNameIsStableAndDistinct() {
        XCTAssertEqual(ImageBlobStore.fileName(for: "same"), ImageBlobStore.fileName(for: "same"))
        XCTAssertNotEqual(ImageBlobStore.fileName(for: "a"), ImageBlobStore.fileName(for: "b"))
        XCTAssertTrue(ImageBlobStore.fileName(for: "x").hasSuffix(".img"))
    }

    func testEmptyDataIsNotStored() throws {
        let (store, _) = try makeStore()
        store.store(Data(), forKey: "empty")
        XCTAssertNil(store.data(forKey: "empty"))
    }

    func testRemoveAllClearsEverything() throws {
        let (store, _) = try makeStore()
        store.store(Data(repeating: 3, count: 100), forKey: "x")
        XCTAssertNotNil(store.data(forKey: "x"))
        store.removeAll()
        XCTAssertNil(store.data(forKey: "x"))
        XCTAssertEqual(store.totalBytes, 0)
    }

    /// 超上限时按最旧优先淘汰。
    ///
    /// 直接写文件而不是走 `store(_:forKey:)`：那个入口每次写完都会自己跑一遍淘汰，
    /// 于是测试**没法在淘汰发生前**把 mtime 拉开——所有文件都是「刚刚」，
    /// 排序退化成任意顺序（这正是本用例第一版失败的原因）。这里手工铺好带
    /// 明确先后关系的文件，再只调一次 `store` 触发淘汰，顺序才是确定的。
    func testPrunesOldestWhenOverLimit() throws {
        let (store, dir) = try makeStore(maxBytes: 10_000)
        let chunk = Data(repeating: 9, count: 3_000)

        // 铺 4 条旧的（各 3KB = 12KB，已超 10KB 上限），mtime 依次变新
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<4 {
            let file = dir.appendingPathComponent(ImageBlobStore.fileName(for: "old\(i)"))
            try chunk.write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(TimeInterval(i))],
                ofItemAtPath: file.path)
        }

        // 写一条新的 → 触发淘汰
        store.store(chunk, forKey: "newest")

        XCTAssertLessThanOrEqual(store.totalBytes, 10_000, "必须已淘汰到上限内")
        XCTAssertNotNil(store.data(forKey: "newest"), "最新的应留下")
        XCTAssertNil(store.data(forKey: "old0"), "最旧的应先被删")
    }

    func testTotalBytesReflectsContent() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.totalBytes, 0)
        store.store(Data(repeating: 2, count: 5000), forKey: "size")
        XCTAssertGreaterThanOrEqual(store.totalBytes, 5000)
    }
}
