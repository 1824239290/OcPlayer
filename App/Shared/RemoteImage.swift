import Foundation
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

    private let session: URLSession
    private let lock = NSLock()
    /// 同一 URL + 认证头的进行中请求共享一个任务：列表滚动反复出现同一张图时不重复拉。
    private var inFlight: [String: Task<PlatformImage?, Error>] = [:]
    /// 解码后的图缓存（URLCache 存的是原始 data，这里省掉重复解码）。
    private let memoryCache = NSCache<NSString, PlatformImage>()

    init(cacheDirectory: URL? = nil) {
        let cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: cacheDirectory
                ?? URL.applicationSupportDirectory.appending(path: "OcPlayer/ImageCache", directoryHint: .isDirectory)
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = [:]
        session = URLSession(configuration: configuration)
    }

    /// 加载一张图。返回 `nil` = 真正失败（下次可重试）；任务被取消会抛 `CancellationError`
    /// （视图消失 / 换 URL 时 `.task(id:)` 自动取消），调用方不要把取消当成失败。
    /// 同一 URL 的并发调用共享同一个网络任务，取消一个订阅者不影响其它订阅者。
    func load(_ url: URL, authHeader: String?) async throws -> PlatformImage? {
        let key = url.absoluteString + "\u{0}" + (authHeader ?? "")
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        let task = startOrJoin(key: key) {
            Task<PlatformImage?, Error> { [weak self] in
                // 不管成败都要从 inFlight 摘掉，否则失败 URL 会永远卡在「进行中」。
                defer { self?.finishInFlight(key: key) }
                guard let self else { return nil }
                let image = try await self.fetch(url, authHeader: authHeader)
                if let image {
                    self.memoryCache.setObject(image, forKey: key as NSString)
                }
                return image
            }
        }
        return try await task.value
    }

    // MARK: - 锁保护（NSLock 不能在 async 上下文直接调，临界区收进同步方法）

    private func startOrJoin(key: String, make: () -> Task<PlatformImage?, Error>)
        -> Task<PlatformImage?, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[key] { return existing }
        let task = make()
        inFlight[key] = task
        return task
    }

    private func finishInFlight(key: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight[key] = nil
    }

    private func fetch(_ url: URL, authHeader: String?) async throws -> PlatformImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        // 取消（视图消失 / 换 URL）会从这里抛 CancellationError，由调用方区分处理。
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PlatformImage(data: data)
    }
}

/// 远程图视图：加载中 / 失败都有落点，占位色跟主题走。
struct RemoteImage: View {
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var loadedURL: URL?

    let url: URL?
    var authHeader: String?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFill()
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
}
