import CoreGraphics
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
    }

    /// Current disk usage and the hard URLCache limit. The 512 MiB capacity is
    /// enforced by Foundation using its eviction policy, so long-running use is
    /// bounded even before a user requests an explicit clear.
    var diskUsage: (usedBytes: Int, capacityBytes: Int) {
        (cache.currentDiskUsage, cache.diskCapacity)
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

    /// 加载一张图。返回 `nil` = 真正失败（下次可重试）；任务被取消会抛 `CancellationError`
    /// （视图消失 / 换 URL 时 `.task(id:)` 自动取消），调用方不要把取消当成失败。
    /// 同一 URL 的并发调用共享同一个网络任务，取消一个订阅者不影响其它订阅者。
    func load(_ url: URL, authHeader: String?) async throws -> PlatformImage? {
        let key = url.absoluteString + "\u{0}" + (authHeader ?? "")
        if let cached = cachedImage(forKey: key) {
            return cached
        }
        let task = startOrJoin(key: key) { requestID, generation in
            Task<PlatformImage?, Error> { [weak self] in
                // 不管成败都要从 inFlight 摘掉，否则失败 URL 会永远卡在「进行中」。
                defer { self?.finishInFlight(key: key, requestID: requestID) }
                guard let self else { return nil }
                let request = self.makeRequest(url, authHeader: authHeader)
                do {
                    let image = try await self.fetch(request)
                    try Task.checkCancellation()
                    guard self.accept(image, forKey: key, generation: generation) else {
                        self.cache.removeCachedResponse(for: request)
                        throw CancellationError()
                    }
                    return image
                } catch {
                    if !self.isCurrentGeneration(generation) {
                        self.cache.removeCachedResponse(for: request)
                    }
                    throw error
                }
            }
        }
        return try await task.value
    }

    // MARK: - 锁保护（NSLock 不能在 async 上下文直接调，临界区收进同步方法）

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
        make: (UUID, UInt64) -> Task<PlatformImage?, Error>
    )
        -> Task<PlatformImage?, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[key] { return existing.task }
        let requestID = UUID()
        let task = make(requestID, cacheGeneration)
        inFlight[key] = InFlightRequest(id: requestID, task: task)
        return task
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
    }

    private func makeRequest(_ url: URL, authHeader: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> PlatformImage? {
        // 取消（视图消失 / 换 URL）会从这里抛 CancellationError，由调用方区分处理。
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // 在 URLSession 的协程线程池上立即解码：`PlatformImage(data:)` 是懒解码，
        // 真正的位图解码会拖到主线程首次绘制时才发生——海报墙快速滚动时每张新图
        // 都在主线程解码、掉帧。这里用 ImageIO 强制解码成位图，主线程首绘不再解码。
        return Self.decode(data)
    }

    /// ImageIO 立即解码（`kCGImageSourceShouldCacheImmediately` 把位图留在内存）。
    private static func decode(_ data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
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
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .animation(imageFade, value: image != nil)
        .task(id: url?.absoluteString) {
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
                let loaded = try await ImagePipeline.shared.load(url, authHeader: authHeader)
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
