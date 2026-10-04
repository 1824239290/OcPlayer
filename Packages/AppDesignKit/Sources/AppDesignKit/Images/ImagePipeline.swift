import DiagnosticsKit
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

public extension Image {
    init(platform image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

/// 海报 / 剧照加载器：独立 URLSession + 磁盘 URLCache（512 MB）+ 内存解码缓存 + 请求去重。
///
/// 认证走 `Authorization` 头（token 不进 URL）；图片 URL 里带 `tag` query，
/// 服务端换图 → URL 变 → 缓存自动失效。
public final class ImagePipeline: @unchecked Sendable {
    public static let shared = ImagePipeline()
    public static let diskCapacityBytes = 512 * 1024 * 1024
    /// 图片失败日志节流：服务器掉线时一墙海报会瞬间刷出几百条 warning，
    /// 别把单文件 20MB / 总量 50MB 的诊断保留窗口全挤掉。
    private static let failureThrottle = DiagnosticThrottle(key: "image-load-failure", interval: 5)
    /// 磁盘命中的图超过这个年龄才在后台回源一次。默认 7 天。
    ///
    /// 为什么可以这么长：图片 URL 通常带 `tag`，服务端换图会改 URL（= 改缓存键），
    /// 本来就取不到旧图。这个阈值只为兜住**没有 tag 的 URL**，压住「永远不更新」。
    static let blobStalenessThreshold: TimeInterval = 7 * 24 * 60 * 60
    /// 同时在途的后台刷新上限。见 `revalidateIfStale` 的三道闸门。
    static let maxConcurrentRevalidations = 4
    /// 与 App 同 subsystem、独立 category：日志仍落在同一份 diagnostics.jsonl，
    /// 但包不反向依赖 App 层（AppDiagnostics）。
    private static let logger = DiagnosticLogger(category: "Image")
    /// 项目统一 UA（对齐 MoviePilot / Jellyfin 客户端的 OcPlay/版本 写法）。
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "OcPlay/\(version) (ImagePipeline)"
    }()

    private let session: URLSession
    private let cache: URLCache
    /// 图片字节的自有磁盘缓存（离线出图靠它，不靠 `URLCache`——后者跨实例读不回来，
    /// 见 `ImageBlobStore` 的类型注释）。
    private let blobStore: ImageBlobStore
    private let lock = NSLock()
    private var cacheGeneration: UInt64 = 0
    /// 同一 URL + 认证头的进行中请求共享一个任务：列表滚动反复出现同一张图时不重复拉。
    private var inFlight: [String: InFlightRequest] = [:]
    /// 正在后台回源刷新的键（去重 + 并发上限，见 `revalidateIfStale`）。
    private var revalidatingKeys: Set<String> = []
    /// 解码后的图缓存（URLCache 存的是原始 data，这里省掉重复解码）。
    private let memoryCache = NSCache<NSString, PlatformImage>()
    /// 位图解码执行器（专用队列 + 并发上限）。见 `ImageDecoder`：解码不能就地同步做，
    /// 否则会占住 Swift 协作线程池的线程，拖慢全进程的 async 工作。
    private let decoder: ImageDecoder

    /// - Parameter protocolClasses: 额外的 `URLProtocol`（供测试挡掉真实网络）。
    ///
    ///   存在的理由是**可测性**：这个类最要紧的行为之一是「缓存命中时不等网络」，
    ///   而验证它需要一个**永不返回**的网络——只有替换协议类才做得到。
    ///   生产调用不传，保持默认行为。
    public init(
        cacheDirectory: URL? = nil,
        decoder: ImageDecoder = .shared,
        protocolClasses: [AnyClass] = []
    ) {
        self.decoder = decoder
        // `CanonicalImageURLCache` 而不是裸 `URLCache`：把键里的服务器地址抹掉，
        // 否则同一台服务器换入口（局域网 ↔ Tailscale）会把每张图再下一遍。
        // 见 `CanonicalImageURLCache` 的类型注释。
        let cache = CanonicalImageURLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: Self.diskCapacityBytes,
            directory: cacheDirectory
                ?? OcPlayerStorage.directory("ImageCache")
        )
        self.cache = cache
        let resolvedCacheDirectory = cacheDirectory ?? OcPlayerStorage.directory("ImageCache")
        // 字节缓存与 URLCache 同目录下的 Blobs/：两者一起被「清空图片缓存」清掉，
        // 报体积时也能一起算。
        self.blobStore = ImageBlobStore(
            directory: resolvedCacheDirectory.appendingPathComponent("Blobs", isDirectory: true))
        // 生产路径（用默认目录）才做一次性清理：注入目录的都是测试，
        // 不该被这个迁移搅动（也不该写生产 UserDefaults）。
        if cacheDirectory == nil {
            let directory = resolvedCacheDirectory
            let blobs = blobStore
            Task.detached(priority: .utility) {
                Self.purgeLegacyKeysIfNeeded(cache: cache, defaults: .standard, directory: directory)
                // 键从「含服务器地址 + 含 App 版本」改成稳定键后，旧字节也读不到了
                // （文件名是键的哈希）。同样只在首次清一次，避免每次启动都清。
                Self.purgeStaleBlobsIfNeeded(store: blobs, defaults: .standard)
            }
        }
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = [:]
        // 图片请求的超时收短：系统默认 60 秒，而图片是**可替代**资源——
        // 服务器连不上时，UI 宁可早点显示占位符，也不该让十几张海报各自挂一分钟。
        // 实测断网时 `-1005` 约 7 秒就返回，所以 15 秒足够覆盖慢速网络下的正常拉取。
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)
        // 解码位图缓存有硬上限：长会话反复刷库也不会无限累积内存。
        // cost 按像素字节数计（见 memoryCost），超限时 NSCache 自动淘汰最旧。
        memoryCache.totalCostLimit = 128 * 1024 * 1024
        memoryCache.countLimit = 500

        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearMemoryCache()
        }
        #endif
    }

    /// 一次性清理：图片缓存键从「完整 URL（含服务器地址）」改成规范化键后，
    /// **旧键永远命不中**，留着只是一堆谁也读不到的死数据（实测用户库上 110 MB）。
    /// 新键本来就要重新下载，所以这次清理**不额外增加任何下载**，只是顺手把
    /// 死数据删掉、把磁盘还给用户。
    ///
    /// 标记写进 UserDefaults：只做一次，之后每次启动不再碰缓存
    /// （否则用户每次开 App 缓存都被清空，等于没有缓存）。
    static func purgeLegacyKeysIfNeeded(
        cache: URLCache,
        defaults: UserDefaults,
        directory: URL
    ) {
        let markerKey = "dev.jumusu.ocplayer.imageCache.canonicalKeysV1"
        guard !defaults.bool(forKey: markerKey) else { return }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: markerKey)
        Self.logger.info("图片缓存键升级：已清空旧键缓存", fields: [
            "directory": .string(directory.lastPathComponent),
        ])
    }

    /// 一次性清理：键从「含服务器地址 + 含 App 版本」换成稳定键后，旧字节的文件名
    /// （键的哈希）再也命不中，留着只是死数据。与 `purgeLegacyKeysIfNeeded` 同理，
    /// 只在首次清一次——每次启动都清等于没有缓存。
    static func purgeStaleBlobsIfNeeded(store: ImageBlobStore, defaults: UserDefaults) {
        let markerKey = "dev.jumusu.ocplayer.imageCache.stableBlobKeysV1"
        guard !defaults.bool(forKey: markerKey) else { return }
        store.removeAll()
        defaults.set(true, forKey: markerKey)
        Self.logger.info("图片字节缓存键升级：已清空旧数据")
    }

    /// Current disk usage and the hard URLCache limit. The 512 MiB capacity is
    /// enforced by Foundation using its eviction policy, so long-running use is
    /// bounded even before a user requests an explicit clear.
    public var diskUsage: (usedBytes: Int, capacityBytes: Int) {
        (cache.currentDiskUsage + blobStore.totalBytes, Self.diskCapacityBytes)
    }

    /// Clears decoded bitmaps from memory.
    public func clearMemoryCache() {
        lock.lock()
        memoryCache.removeAllObjects()
        lock.unlock()
    }

    /// Clears both encoded response data and decoded bitmaps. URLCache and
    /// NSCache provide their own synchronization, so Settings can call this
    /// directly without reaching into the cache directory.
    public func clearCache() {
        lock.lock()
        cacheGeneration &+= 1
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        cache.removeAllCachedResponses()
        memoryCache.removeAllObjects()
        lock.unlock()
        blobStore.removeAll()
        tasks.forEach { $0.cancel() }
    }

    /// 同步获取内存缓存中的位图（若存在）；未命中或未解码返回 nil。
    public func memoryCachedImage(url: URL, authHeader: String?, maxPixelSize: Int? = nil) -> PlatformImage? {
        let key = requestKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
        return cachedImage(forKey: key)
    }

    /// 加载一张图。返回 `nil` = 真正失败（下次可重试）。
    ///
    /// 同一 URL 的并发调用共享同一个网络任务（列表滚动反复出现同一张图时不重复拉）；
    /// 共享任务在**最后一个订阅者离开**时被取消（视图消失 / 换 URL / clearCache），
    /// 调用方被取消会抛 `CancellationError`——不要把取消当成失败。
    public func load(_ url: URL, authHeader: String?, maxPixelSize: Int? = nil) async throws -> PlatformImage? {
        let key = requestKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
        if let cached = cachedImage(forKey: key) {
            return cached
        }
        let subscriptionID = UUID()
        let task = startOrJoin(key: key, subscriptionID: subscriptionID) { requestID, generation in
            Task<PlatformImage?, Error> { [weak self] in
                // 不管成败都要从 inFlight 摘掉，否则失败的 URL 会永远卡在「进行中」。
                defer { self?.finishInFlight(key: key, requestID: requestID) }
                guard let self else { return nil }
                // ① **先读磁盘**：命中就直接用，**发起网络之前**。
                //
                // 这里曾经把兜底写在 `catch` 里（网络失败再读磁盘），后果是断网时
                // **每张图都要先等网络超时**——实测每次 `-1005 连接中断` 约 7 秒，
                // 首页十几张图就是十几秒起步，用户直接问「为什么离线加载要这么久」。
                // 缓存就在本地，没有任何理由让网络先跑一趟。
                //
                // 与 `URLCache` 的 `.returnCacheDataElseLoad` 语义一致（缓存优先、
                // 不回源校验），所以这不是把「新鲜度」换成了「速度」；额外还做了
                // 后台刷新（见 `revalidateIfStale`），比原来更不容易陈旧。
                if let image = try await self.imageFromBlobStore(key: key, maxPixelSize: maxPixelSize) {
                    _ = self.accept(image, forKey: key, generation: generation)
                    self.revalidateIfStale(
                        url: url, authHeader: authHeader, cacheKey: key, maxPixelSize: maxPixelSize)
                    return image
                }

                let request = self.makeRequest(url, authHeader: authHeader)
                do {
                    let image = try await self.fetch(request, cacheKey: key, maxPixelSize: maxPixelSize)
                    try Task.checkCancellation()
                    guard self.accept(image, forKey: key, generation: generation) else {
                        self.cache.removeCachedResponse(for: request)
                        throw CancellationError()
                    }
                    return image
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // **离线兜底**：网络失败时读自有的字节缓存。
                    //
                    // 这一条是用户可见功能的关键——「断网重启后海报还在」。不能只靠
                    // `URLCache`：实测它跨实例（= 重启）读不回来，条目在库里也白搭。
                    // 字节缓存由我们写、我们读，键又与服务器地址无关，所以离线必命中。
                    if let data = self.blobStore.data(forKey: key),
                       let cached = try? await self.decoder.decode(data, maxPixelSize: maxPixelSize),
                       self.isCurrentGeneration(generation) {
                        Self.logger.info("图片走离线缓存", fields: [
                            "url": .string(url.absoluteString),
                            "bytes": .integer(Int64(data.count)),
                        ], throttle: Self.failureThrottle)
                        _ = self.accept(cached, forKey: key, generation: generation)
                        return cached
                    }
                    Self.logger.warning("图片加载失败", fields: [
                        "url": .string(url.absoluteString),
                        "error": .string("\(error)"),
                    ], throttle: Self.failureThrottle)
                    if !self.isCurrentGeneration(generation) {
                        self.cache.removeCachedResponse(for: request)
                    }
                    throw error
                }
            }
        }
        // 正常路径也要注销订阅；取消路径靠 onCancel 注销（leave 幂等）。
        defer { leave(key: key, subscriptionID: subscriptionID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            leave(key: key, subscriptionID: subscriptionID)
        }
    }

    // MARK: - 磁盘字节缓存（离线/冷启动的主路径）

    /// 从字节缓存取图并解码。nil = 没有这条或确实解不出（两种都该走网络）。
    ///
    /// 解码**必须**走 `decoder`（专用队列 + 并发上限），理由同 `fetch` 里的长注释：
    /// 就地同步解码会占住协作线程池的线程，海报墙并发十几张就能拖慢全进程。
    ///
    /// **取消与真失败必须分开**（这里踩过一次）：`ImageDecoder.decode` 在**排队期间
    /// 被取消**时抛 `CancellationError`（视图滚走 / 代次作废，快速滚动时是常态），
    /// 而字节确实解不出位图时返回 `nil`。用 `try?` 会把两者都收敛成 `nil`，
    /// 于是「取消」被当成「坏数据」→ **把完好的缓存删掉**，缓存越用越少。
    /// 所以：取消原样上抛（交给外层当作取消处理），只有真 `nil` 才丢弃。
    private func imageFromBlobStore(key: String, maxPixelSize: Int?) async throws -> PlatformImage? {
        guard let data = blobStore.data(forKey: key) else { return nil }
        guard let image = try await decoder.decode(data, maxPixelSize: maxPixelSize) else {
            // 真失败（截断 / 格式变化）：删掉它，免得每次启动都白读一遍坏数据。
            Self.logger.warning("磁盘图片解码失败，已丢弃", fields: [
                "key": .string(key.suffix(48).description),
                "bytes": .integer(Int64(data.count)),
            ], throttle: Self.failureThrottle)
            blobStore.remove(forKey: key)
            return nil
        }
        return image
    }

    /// 后台刷新：磁盘命中后，若这条已经旧了就悄悄回源一次。
    ///
    /// 为什么需要它：磁盘优先意味着「有就不问网络」。图片 URL 里通常带 `tag`
    /// （服务端换图 → URL 变 → 键变），所以多数情况不会陈旧；但**没有 tag 的 URL**
    /// 就永远不会更新。加一层按时间的后台校验，把「可能陈旧」压到可接受范围。
    ///
    /// 三道闸门，防住「几百张海报同时回源」：
    /// 1. **新鲜度阈值**（默认 7 天）：刚下载的不刷。用 `creationDate`（下载时间），
    ///    不是 mtime——后者读取时会被刷新成「刚刚」。
    /// 2. **同键去重**：同一张图在途刷新中就不再排第二个。
    /// 3. **并发上限**（默认 4）：超出就跳过这次刷新（下次启动/再次出现还有机会）。
    ///    宁可少刷一次，也不要在用户翻页时突然打出上百个请求。
    private func revalidateIfStale(
        url: URL,
        authHeader: String?,
        cacheKey: String,
        maxPixelSize: Int?
    ) {
        guard let downloadedAt = blobStore.downloadedAt(forKey: cacheKey) else {
            // 取不到下载时间（条目已被淘汰 / 属性读不出）：当作陈旧，但不主动刷——
            // 下一次真正需要它时还有机会。这里保守跳过，避免读不到就狂刷。
            return
        }
        guard Date().timeIntervalSince(downloadedAt) >= Self.blobStalenessThreshold else { return }

        guard beginRevalidation(cacheKey: cacheKey) else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.endRevalidation(cacheKey: cacheKey) }
            // 刷新失败（离线）完全静默：图已经在屏幕上，这不是错误。
            // 也别用它替换内存缓存——那会让用户眼前的图突然跳变。
            let request = self.makeRequest(url, authHeader: authHeader)
            _ = try? await self.fetch(request, cacheKey: cacheKey, maxPixelSize: maxPixelSize)
        }
    }

    // MARK: - 锁保护（NSLock 不能在 async 上下文直接调，临界区收进同步方法）

    /// 请求去重 / 内存缓存 / **磁盘字节缓存**共用的 key。
    ///
    /// 两处讲究：
    ///
    /// 1. **URL 部分走规范化**（`ImageCacheKey.canonicalURL`）：抹掉服务器地址。
    ///    否则同一张图在局域网与 Tailscale 下是不同的 key，字节缓存各存一份、
    ///    换地址后还要重下——这正是本次要修的。媒体服务器图片一律能规范化；
    ///    公开图床（`image.tmdb.org` 等）返回 nil，退回原始 URL（它们只有一条地址）。
    /// 2. **认证头只留稳定哈希**：它可能出现在 SwiftUI 的 view identity 与诊断输出里，
    ///    且用 `String.hashValue` 会**每进程随机化**——那会让磁盘字节缓存每次启动全部
    ///    失效。这里用 `ImageCacheKey.authIdentity`（只取 DeviceId + Token 的 FNV1a 哈希），
    ///    跨进程稳定，且不随 App 版本变化（版本号曾在里面，见该方法的说明）。
    private func requestKey(url: URL, authHeader: String?, maxPixelSize: Int?) -> String {
        let canonical = ImageCacheKey.canonicalURL(for: url, authHeader: authHeader)?.absoluteString
            ?? url.absoluteString
        let identity = ImageCacheKey.authIdentity(authHeader)
        return canonical + "\u{0}" + identity + "\u{0}" + "\(maxPixelSize ?? 0)"
    }

    /// 认领一次后台刷新（同键去重 + 并发上限）。false = 这次不刷。
    ///
    /// 收成同步方法是因为 `NSLock` 不能在 async 上下文直接加解锁
    /// （Swift 6 对此有专门的编译错误，本文件既有约定）。
    private func beginRevalidation(cacheKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !revalidatingKeys.contains(cacheKey) else { return false }
        guard revalidatingKeys.count < Self.maxConcurrentRevalidations else { return false }
        revalidatingKeys.insert(cacheKey)
        return true
    }

    private func endRevalidation(cacheKey: String) {
        lock.lock()
        revalidatingKeys.remove(cacheKey)
        lock.unlock()
    }

    private func cachedImage(forKey key: String) -> PlatformImage? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache.object(forKey: key as NSString)
    }

    private func accept(_ image: PlatformImage?, forKey key: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cacheGeneration == generation else { return false }
        if let image {
            memoryCache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))
        }
        return true
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cacheGeneration == generation
    }

    private func startOrJoin(
        key: String,
        subscriptionID: UUID,
        make: (UUID, UInt64) -> Task<PlatformImage?, Error>
    )
        -> Task<PlatformImage?, Error> {
        lock.lock()
        defer { lock.unlock() }
        if var existing = inFlight[key] {
            existing.subscribers.insert(subscriptionID)
            inFlight[key] = existing
            return existing.task
        }
        let requestID = UUID()
        let task = make(requestID, cacheGeneration)
        inFlight[key] = InFlightRequest(id: requestID, task: task, subscribers: [subscriptionID])
        return task
    }

    /// 注销一个订阅者；最后一个订阅者离开时取消底层任务（否则滚动经过的
    /// 海报也会把整张图下载完并解码完，白烧带宽和 CPU）。
    /// 幂等：同一个 subscriptionID 只注销一次（正常路径的 defer 与取消路径的 onCancel 都会调）。
    private func leave(key: String, subscriptionID: UUID) {
        var taskToCancel: Task<PlatformImage?, Error>?
        lock.lock()
        if var entry = inFlight[key] {
            entry.subscribers.remove(subscriptionID)
            if entry.subscribers.isEmpty {
                inFlight[key] = nil
                taskToCancel = entry.task
            } else {
                inFlight[key] = entry
            }
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    private func finishInFlight(key: String, requestID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if inFlight[key]?.id == requestID {
            inFlight[key] = nil
        }
    }

    private struct InFlightRequest {
        let id: UUID
        let task: Task<PlatformImage?, Error>
        /// 当前等待这个请求的订阅者（并发调用同一 URL 的视图）。
        var subscribers: Set<UUID>
    }

    private func makeRequest(_ url: URL, authHeader: String?) -> URLRequest {
        // 协议由连接时选择的 HTTP/HTTPS 决定(url 来自服务器 baseURL),这里不去 inline 改 url 的 scheme,
        // 避免「画面走 http、图片被强转 https」的不一致。
        let targetURL = url
        var request = URLRequest(url: targetURL)
        request.cachePolicy = .returnCacheDataElseLoad
        if let host = targetURL.host, host.contains("bgm.tv") {
            // bgm 图床按浏览器 UA + Referer 防盗链；其它图源（含自家 Jellyfin）用项目统一 UA，
            // 别把假 UA 无条件下发给所有图片请求（与服务端指纹约定不一致，也容易被当爬虫）。
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://bgm.tv/", forHTTPHeaderField: "Referer")
        } else {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetch(_ request: URLRequest, cacheKey: String, maxPixelSize: Int? = nil) async throws -> PlatformImage? {
        // 最后一个订阅者离开（视图消失 / 换 URL）或 clearCache 会取消底层任务，
        // 从这里抛 CancellationError，由调用方区分处理，别当成真正的失败。
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.warning("图片请求失败：无 HTTP 响应", fields: [
                "url": .string(request.url?.absoluteString ?? "")
            ], throttle: Self.failureThrottle)
            return nil
        }
        guard httpResponse.statusCode == 200 else {
            Self.logger.warning("图片请求返回非 200", fields: [
                "url": .string(request.url?.absoluteString ?? ""),
                "status": .integer(Int64(httpResponse.statusCode)),
            ], throttle: Self.failureThrottle)
            return nil
        }
        // 在 URLSession 的协程线程池上立即解码：`PlatformImage(data:)` 是懒解码，
        // 真正的位图解码会拖到主线程首次绘制时才发生——海报墙快速滚动时每张新图
        // 都在主线程解码、掉帧。这里用 ImageIO 强制解码成位图，主线程首绘不再解码。
        //
        // ⚠️ 解码**必须走 `ImageDecoder`**（专用队列 + 并发上限），不能就地同步调：
        // 立即解码一张 50–200ms，在这里直接做会占住 Swift 协作线程池的线程，
        // 而协作池线程数≈活跃核数——海报墙并发十几张就能把全进程的 async 工作拖慢。
        // `Task.detached` 解决不了（它同样跑在协作池上），只有专用队列才行。
        guard let image = try await decoder.decode(data, maxPixelSize: maxPixelSize) else {
            Self.logger.warning("图片解码失败", fields: [
                "url": .string(request.url?.absoluteString ?? ""),
                "data_len": .integer(Int64(data.count)),
            ], throttle: Self.failureThrottle)
            return nil
        }
        // 存**编码后的字节**（JPEG/PNG 原样）：离线时自己解码就能出图，
        // 不必依赖 URLCache 的可读性（见 `ImageBlobStore`）。
        blobStore.store(data, forKey: cacheKey)
        return image
    }

    /// 位图近似内存占用（字节）。NSCache 用 cost 做总上限淘汰。
    private static func memoryCost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let cg = image.cgImage
        #else
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let cg else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}

// MARK: - 注入点

private struct ImagePipelineKey: EnvironmentKey {
    static let defaultValue = ImagePipeline.shared
}

public extension EnvironmentValues {
    /// 图片管道，供 `RemoteImage` / `MediaArtwork` 取用。
    ///
    /// 存在的理由是**可测性**：这两个类型此前硬编码 `ImagePipeline.shared`，
    /// 于是包内最复杂的组件（去重、订阅计数、代次作废、缓存淘汰）一个用例都写不了 ——
    /// 测试没法替换缓存/会话，也没法为自己的用法写回归。有了注入点，
    /// 测试可以塞一个挂了 `MockURLProtocol` 的实例进来。
    ///
    /// 装配侧不必改：默认值就是 `.shared`，14 个调用点零改动即拿到生产行为。
    var imagePipeline: ImagePipeline {
        get { self[ImagePipelineKey.self] }
        set { self[ImagePipelineKey.self] = newValue }
    }
}
