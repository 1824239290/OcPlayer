import CoreGraphics
import DiagnosticsKit
import Foundation
import ImageIO
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
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
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()
    static let diskCapacityBytes = 512 * 1024 * 1024
    /// 图片失败日志节流：服务器掉线时一墙海报会瞬间刷出几百条 warning，
    /// 别把 2MB×3 轮转的诊断历史全挤掉。
    private static let failureThrottle = DiagnosticThrottle(key: "image-load-failure", interval: 5)
    /// 项目统一 UA（对齐 MoviePilot / Jellyfin 客户端的 OcPlay/版本 写法）。
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "OcPlay/\(version) (ImagePipeline)"
    }()

    private let session: URLSession
    private let cache: URLCache
    private let lock = NSLock()
    private var cacheGeneration: UInt64 = 0
    /// 同一 URL + 认证头的进行中请求共享一个任务：列表滚动反复出现同一张图时不重复拉。
    private var inFlight: [String: InFlightRequest] = [:]
    /// 解码后的图缓存（URLCache 存的是原始 data，这里省掉重复解码）。
    private let memoryCache = NSCache<NSString, PlatformImage>()

    init(cacheDirectory: URL? = nil) {
        let cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: Self.diskCapacityBytes,
            directory: cacheDirectory
                ?? URL.applicationSupportDirectory.appending(path: "OcPlayer/ImageCache", directoryHint: .isDirectory)
        )
        self.cache = cache
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = [:]
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

    /// Current disk usage and the hard URLCache limit. The 512 MiB capacity is
    /// enforced by Foundation using its eviction policy, so long-running use is
    /// bounded even before a user requests an explicit clear.
    var diskUsage: (usedBytes: Int, capacityBytes: Int) {
        (cache.currentDiskUsage, cache.diskCapacity)
    }

    /// Clears decoded bitmaps from memory.
    func clearMemoryCache() {
        lock.lock()
        memoryCache.removeAllObjects()
        lock.unlock()
    }

    /// Clears both encoded response data and decoded bitmaps. URLCache and
    /// NSCache provide their own synchronization, so Settings can call this
    /// directly without reaching into the cache directory.
    func clearCache() {
        lock.lock()
        cacheGeneration &+= 1
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        cache.removeAllCachedResponses()
        memoryCache.removeAllObjects()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    /// 同步获取内存缓存中的位图（若存在）；未命中或未解码返回 nil。
    func memoryCachedImage(url: URL, authHeader: String?, maxPixelSize: Int? = nil) -> PlatformImage? {
        let key = requestKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
        return cachedImage(forKey: key)
    }

    /// 加载一张图。返回 `nil` = 真正失败（下次可重试）。
    ///
    /// 同一 URL 的并发调用共享同一个网络任务（列表滚动反复出现同一张图时不重复拉）；
    /// 共享任务在**最后一个订阅者离开**时被取消（视图消失 / 换 URL / clearCache），
    /// 调用方被取消会抛 `CancellationError`——不要把取消当成失败。
    func load(_ url: URL, authHeader: String?, maxPixelSize: Int? = nil) async throws -> PlatformImage? {
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
                let request = self.makeRequest(url, authHeader: authHeader)
                do {
                    let image = try await self.fetch(request, maxPixelSize: maxPixelSize)
                    try Task.checkCancellation()
                    guard self.accept(image, forKey: key, generation: generation) else {
                        self.cache.removeCachedResponse(for: request)
                        throw CancellationError()
                    }
                    return image
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    AppDiagnostics.logWarning("图片加载失败", fields: [
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

    // MARK: - 锁保护（NSLock 不能在 async 上下文直接调，临界区收进同步方法）

    /// 请求去重 / 内存缓存的 key。认证头不直接进 key——它可能出现在 SwiftUI 的
    /// view identity 与诊断输出里——只保留进程内稳定的哈希（同 token 同哈希，
    /// 换 token 自然换 key，与直接拼完整头的失效语义一致）。
    private func requestKey(url: URL, authHeader: String?, maxPixelSize: Int?) -> String {
        let authIdentity = authHeader.map { String($0.hashValue) } ?? "none"
        return url.absoluteString + "\u{0}" + authIdentity + "\u{0}" + "\(maxPixelSize ?? 0)"
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

    private func fetch(_ request: URLRequest, maxPixelSize: Int? = nil) async throws -> PlatformImage? {
        // 最后一个订阅者离开（视图消失 / 换 URL）或 clearCache 会取消底层任务，
        // 从这里抛 CancellationError，由调用方区分处理，别当成真正的失败。
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            AppDiagnostics.logWarning("图片请求失败：无 HTTP 响应", fields: [
                "url": .string(request.url?.absoluteString ?? "")
            ], throttle: Self.failureThrottle)
            return nil
        }
        guard httpResponse.statusCode == 200 else {
            AppDiagnostics.logWarning("图片请求返回非 200", fields: [
                "url": .string(request.url?.absoluteString ?? ""),
                "status": .integer(Int64(httpResponse.statusCode)),
            ], throttle: Self.failureThrottle)
            return nil
        }
        // 在 URLSession 的协程线程池上立即解码：`PlatformImage(data:)` 是懒解码，
        // 真正的位图解码会拖到主线程首次绘制时才发生——海报墙快速滚动时每张新图
        // 都在主线程解码、掉帧。这里用 ImageIO 强制解码成位图，主线程首绘不再解码。
        guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else {
            AppDiagnostics.logWarning("图片解码失败", fields: [
                "url": .string(request.url?.absoluteString ?? ""),
                "data_len": .integer(Int64(data.count)),
            ], throttle: Self.failureThrottle)
            return nil
        }
        return image
    }

    /// ImageIO 立即解码（`kCGImageSourceShouldCacheImmediately` 把位图留在内存）。
    /// 指定 `maxPixelSize` 时通过缩略图模式下采样，大幅降低外部高清图内存占用。
    private static func decode(_ data: Data, maxPixelSize: Int? = nil) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let cgImage: CGImage?
        if let maxPixelSize, maxPixelSize > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
            ]
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let cgImage else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
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

/// 远程图视图：加载中 / 失败都有落点，占位色跟主题走。
struct RemoteImage: View {
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var loadedURL: URL?

    let url: URL?
    var authHeader: String?
    /// 解码目标最大长边像素数；指定后通过 ImageIO 进行下采样，大幅降低大图内存开销。
    var maxPixelSize: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 常驻底层：加载中就是它在当占位，图片到位后从它上面淡入。
            // 灰度取 `Metrics.placeholderFill`，和骨架块同一个值——否则骨架撤掉、
            // 真实卡片上位而图还没下载完的那一瞬间，整墙灰会「变深一档」。
            Rectangle().fill(Metrics.placeholderFill)
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFill()
                    // 加载完成在占位层上淡入，不再硬弹出；换 URL 清空旧图时沿同一过渡淡出。
                    .transition(.opacity)
            } else if failed || url == nil {
                // 没有地址（该条目本来就没有这种图）和加载失败共用落点：
                // 显示静态占位图标。否则 url 为 nil 时会永远转圈（task 里被 guard 挡掉）。
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            // 加载中不需要额外分支：底层那块灰就是占位（原来这里又画了一块
            // 一模一样的 Rectangle，视觉上是 no-op，只多一层合成）。
        }
        .clipped()
        .animation(imageFade, value: image != nil)
        .task(id: "\(url?.absoluteString ?? "")#\(authHeader.map { String($0.hashValue) } ?? "none")#\(maxPixelSize ?? 0)") {
            // A row can keep its SwiftUI identity while its media value changes
            // (season switching / refresh). Clear the previous bitmap before
            // loading the new URL, otherwise the old poster can sit beside the
            // new title until another redraw.
            guard let url else {
                image = nil
                loadedURL = nil
                failed = false
                return
            }
            // 只有成功过的 URL 才跳过重载：失败的不记 loadedURL，
            // 视图再次出现时还能重试（瞬时断网不该让这张图永远 404 下去）。
            guard loadedURL != url else { return }
            image = nil
            loadedURL = nil
            failed = false
            do {
                let loaded = try await ImagePipeline.shared.load(url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }   // 换 URL / 消失：新任务会接手，别写旧图
                if let loaded {
                    image = loaded
                    loadedURL = url
                } else {
                    failed = true
                }
            } catch {
                // 只把真正的失败当失败：任务取消（视图消失 / 换 URL）不算，
                // 下次出现时 `.task(id:)` 会重新走一遍。
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    /// 图片出现/消失的淡入淡出；减弱动态效果时直接切换，不播动画。
    private var imageFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}
