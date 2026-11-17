import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 把图片成功回调按显示帧分批应用，避免一墙图片同时完成时集中 invalidation。
///
/// 队列使用 FIFO head 游标；取消只把槽位置空，跳过取消项不消耗帧预算。
/// 队列达到上限时会在非重入场景先消费一帧腾位；重入生产达到硬上限时拒绝新项。
@MainActor
public final class ImageArrivalScheduler {
    public struct Arrival: Hashable, Sendable {
        fileprivate let identifier: UInt64
    }

    public static let shared = ImageArrivalScheduler()

    public let frameBudget: Int
    public let pendingLimit: Int
    public private(set) var pendingCount = 0

    private let frameInterval: TimeInterval
    private let driverMode: DriverMode
    private let frameTarget = ImageArrivalFrameTarget()

    private var entries: [Entry?] = []
    private var head = 0
    private var nextIdentifier: UInt64 = 0
    private var isDraining = false
    private var displayLink: CADisplayLink?
    private var timer: Timer?

    private struct Entry {
        let identifier: UInt64
        let action: @MainActor () -> Void
    }

    enum DriverMode {
        case automatic
        case manual
    }

    public convenience init(frameBudget: Int = 4, pendingLimit: Int = 256) {
        self.init(
            frameBudget: frameBudget,
            pendingLimit: pendingLimit,
            frameInterval: 1.0 / 60.0,
            driverMode: .automatic
        )
    }

    init(
        frameBudget: Int,
        pendingLimit: Int,
        frameInterval: TimeInterval,
        driverMode: DriverMode
    ) {
        self.frameBudget = max(1, frameBudget)
        self.pendingLimit = max(1, pendingLimit)
        self.frameInterval = max(1.0 / 240.0, frameInterval)
        self.driverMode = driverMode
        frameTarget.scheduler = self
    }

    /// `isolated deinit`：`CADisplayLink` / `Timer` 是非 Sendable 的主线程对象，
    /// 只能在主 actor 上失效。普通 `deinit` 是 nonisolated 的，Swift 6 会直接拒绝访问。
    isolated deinit {
        displayLink?.invalidate()
        timer?.invalidate()
    }

    /// 入队一次主线程状态应用。返回的令牌可在视图换 URL 或消失时取消。
    @discardableResult
    public func enqueue(_ action: @escaping @MainActor () -> Void) -> Arrival? {
        if pendingCount >= pendingLimit {
            // 不用无界 backlog 换可靠性：正常生产者先按帧消费一批再入队。
            // 正在 drain 时不递归消费，保持帧预算与调用栈都可预测。
            guard !isDraining else { return nil }
            drainFrame()
        }
        guard pendingCount < pendingLimit else { return nil }

        nextIdentifier &+= 1
        let arrival = Arrival(identifier: nextIdentifier)
        entries.append(Entry(identifier: nextIdentifier, action: action))
        pendingCount += 1
        startDriverIfNeeded()
        return arrival
    }

    /// 取消尚未执行的项；已执行或已出队的令牌是幂等 no-op。
    public func cancel(_ arrival: Arrival?) {
        guard let arrival, pendingCount > 0 else { return }
        if head < entries.count {
            for index in head..<entries.count where entries[index]?.identifier == arrival.identifier {
                entries[index] = nil
                pendingCount -= 1
                break
            }
        }
        if pendingCount == 0 {
            stopDriver()
        }
        compactQueueIfNeeded()
    }

    /// 消费一帧预算。DisplayLink / Timer 与测试共用同一个入口。
    func drainFrame() {
        guard !isDraining else { return }
        isDraining = true

        var applied = 0
        while applied < frameBudget, head < entries.count {
            let index = head
            head += 1
            // 取消项只占槽位，不占这一帧的应用预算。
            guard let entry = entries[index] else { continue }
            entries[index] = nil
            pendingCount -= 1
            entry.action()
            applied += 1
        }

        isDraining = false
        compactQueueIfNeeded()
        if pendingCount == 0 {
            stopDriver()
        } else {
            startDriverIfNeeded()
        }
    }

    private func compactQueueIfNeeded() {
        guard !isDraining else { return }
        if head == entries.count {
            entries.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= entries.count {
            // 大段消费后偶尔 amortized compact；热路径不做 removeFirst(1)。
            entries.removeFirst(head)
            head = 0
        }
    }

    private func startDriverIfNeeded() {
        guard driverMode == .automatic, pendingCount > 0,
              displayLink == nil, timer == nil else { return }

        #if canImport(UIKit)
        let link = CADisplayLink(
            target: frameTarget,
            selector: #selector(ImageArrivalFrameTarget.tick)
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        #elseif canImport(AppKit)
        if let link = NSScreen.main?.displayLink(
            target: frameTarget,
            selector: #selector(ImageArrivalFrameTarget.tick)
        ) {
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            startTimerFallback()
        }
        #else
        startTimerFallback()
        #endif
    }

    private func startTimerFallback() {
        let timer = Timer(
            timeInterval: frameInterval,
            target: frameTarget,
            selector: #selector(ImageArrivalFrameTarget.tick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDriver() {
        displayLink?.invalidate()
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 测试观测

    var headCursorForTesting: Int { head }
    var storageCountForTesting: Int { entries.count }
    var isDrainingForTesting: Bool { isDraining }
}

/// DisplayLink / Timer 的 selector target。弱引用避免 RunLoop 与调度器形成保留环。
@MainActor
private final class ImageArrivalFrameTarget: NSObject {
    weak var scheduler: ImageArrivalScheduler?

    @objc func tick() {
        scheduler?.drainFrame()
    }
}
