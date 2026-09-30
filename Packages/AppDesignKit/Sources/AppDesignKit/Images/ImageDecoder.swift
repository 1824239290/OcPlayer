import CoreGraphics
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 图片解码执行器：把位图解码放到**专用队列**上，并限定并发。
///
/// ## 为什么要专用队列，而不是 `Task {}` / `Task.detached {}`
///
/// 这里容易踩一个坑：`Task.detached` **并不会**让同步工作离开 Swift 协作线程池 ——
/// 它和 `Task {}` 跑在同一个协作池上，区别只是不继承 actor / 优先级 / task-local。
/// 而协作池的线程数约等于活跃核数，池内做同步阻塞（位图解码一张 50–200ms，
/// `kCGImageSourceShouldCacheImmediately` 是**立即解码**、不做懒加载）会拖住
/// **全进程**所有 nonisolated async / actor 工作：海报墙快速滚动时并发解码十几张，
/// 起播、网络、数据库全都跟着变慢。这不是"某个函数慢"，是线程池被占满。
///
/// 所以这里用 `OperationQueue`（自带并发上限，就是为这类场景设计的），
/// 解码真正跑在自己的线程上，协作池只管挂起等待。
///
/// ## 并发上限
///
/// 4：够让海报墙滚动时解码跟得上，又不至于让 8/12 核机器被内存带宽打满
/// （解码是内存带宽密集型，开太多反而都变慢）。
public final class ImageDecoder: @unchecked Sendable {

    /// 进程共享实例。测试可另建（`OperationQueue` 参数可调）以验证上限行为。
    public static let shared = ImageDecoder()

    private let queue: OperationQueue

    public init(maxConcurrentDecodes: Int = 4) {
        let queue = OperationQueue()
        queue.name = "dev.jumusu.OcPlayer.image-decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentDecodes)
        self.queue = queue
    }

    /// 并发上限（测试与诊断用）。
    public var maxConcurrentDecodes: Int { queue.maxConcurrentOperationCount }

    /// 当前排队 + 执行中的解码数（测试用；也便于将来做"解码积压"告警）。
    public var pendingDecodeCount: Int { queue.operationCount }

    /// 同时在执行的解码峰值（诊断 + 测试用）。
    ///
    /// 存在的理由：并发上限是本组件存在的一半理由，而"上限没生效"这件事静态看不出来 ——
    /// 没有这个读数，测试只能断言"上限值被写进了 OperationQueue"，
    /// 那是断言配置而不是断言行为（改了 `maxConcurrentOperationCount` 的写法就失效）。
    public var peakConcurrentDecodes: Int { counters.withLock { $0.peak } }

    /// 已完成的解码总数（测试用：确认限流不会把任务丢掉）。
    public var completedDecodeCount: Int { counters.withLock { $0.completed } }

    private struct Counters {
        var active = 0
        var peak = 0
        var completed = 0
    }
    private let counters = Locked(Counters())

    /// 解码为位图。
    ///
    /// 取消语义与调用链一致：外层任务被取消（视图消失 / 换 URL）时抛
    /// `CancellationError`，而不是返回 nil —— 返回 nil 会被上层当成"解码失败"
    /// 落进失败态，于是滑过去的图会留下错误占位。调用方（`ImagePipeline.fetch`）
    /// 已有 `catch is CancellationError` 分支专门处理它。
    public func decode(_ data: Data, maxPixelSize: Int?) async throws -> PlatformImage? {
        let cancellation = DecodeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    // 排队期间就被取消的：别白解一张（快速滚动时这是常态）。
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.enterDecode()
                    defer { self.leaveDecode() }
                    if let image = Self.decodeSynchronously(data, maxPixelSize: maxPixelSize) {
                        continuation.resume(returning: image)
                    } else {
                        // nil = 数据确实解不出位图，是**真失败**，与取消区分开。
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// 同步解码（只在 `queue` 的线程上调用）。
    ///
    /// `kCGImageSourceShouldCacheImmediately` 让位图在这里就解出来：否则
    /// `PlatformImage(data:)` 是懒解码，真正的解码会拖到主线程首绘时才发生 ——
    /// 海报墙快速滚动时每张新图都在主线程解码、掉帧。
    /// 指定 `maxPixelSize` 时走缩略图模式下采样，大幅降低外部高清图的内存占用。
    static func decodeSynchronously(_ data: Data, maxPixelSize: Int?) -> PlatformImage? {
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
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// 取消标记的跨线程传递盒（`onCancel` 在任意线程回调）。
    private final class DecodeCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private func enterDecode() {
        counters.withLock {
            $0.active += 1
            $0.peak = max($0.peak, $0.active)
        }
    }

    private func leaveDecode() {
        counters.withLock {
            $0.active -= 1
            $0.completed += 1
        }
    }
}

/// 极小的加锁盒子（本包已有 `NSLock.withLock` 的用法，这里只是省一层手写）。
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
