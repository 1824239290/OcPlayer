import Foundation
import PlaybackKit
import QuartzCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 帧驱动：`CADisplayLink` 跑在**专用渲染线程**的 runloop 上，不占主线程。
///
/// 每次回调把该帧的**绝对呈现时间**（`targetTimestamp`，与 `CACurrentMediaTime()` 同源）交给
/// `tick`，正好是 `erika_presenter_render_tick` 要的语义。
///
/// macOS 14+ 用 `NSView.displayLink(target:selector:)`（跟随视图所在显示器，取代已弃用的
/// `CVDisplayLink`）；iOS 直接构造 `CADisplayLink`。
final class RenderLoop {
    /// 每帧回调，参数是该帧的绝对呈现时间（秒）。由 `ErikaEngine` 在 init 末尾装上。
    var onTick: (@Sendable (Double) -> Void)?
    private var thread: RenderThread?
    /// `let` + 内部加锁：暂停档位的开关可以从任意线程写，渲染线程每帧读。
    /// 不挂在 `thread` 上——那个引用会被 `stop()` 从主线程清掉，读写就撞上了。
    private let frameRate = FrameRatePolicy()

    /// 必须在主线程调用（要摸视图；`NSView.displayLink` 本身就是 main actor 隔离的）。
    @MainActor
    func start(on view: PlatformView) {
        guard thread == nil, let onTick else { return }
        let proxy = TickProxy(tick: onTick, frameRate: frameRate)
        #if os(macOS)
        let link = view.displayLink(target: proxy, selector: #selector(TickProxy.step(_:)))
        #else
        let link = CADisplayLink(target: proxy, selector: #selector(TickProxy.step(_:)))
        #endif
        // 记下 link 自己的初始档位，恢复播放时写回去：比依赖 `CAFrameRateRangeDefault`
        // 的 Swift 拼写更稳，也自然跟随所在显示器的原生刷新率。
        // 此刻 link 还没进 runloop、渲染线程也还没启动，读它没有竞争。
        frameRate.prime(defaultRange: link.preferredFrameRateRange)

        let thread = RenderThread(link: link, proxy: proxy)
        thread.name = "dev.jumusu.OcPlayer.render"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// 暂停时把帧率降下来（可从任意线程调用，实际生效在渲染线程的下一帧）。
    ///
    /// **不能直接停掉 link**：seek 后的重绘、resize 后的首帧、字幕/弹幕配置变更都靠
    /// 同一条 tick 出画面，事件轮询也挂在上面，停了就再也不动了。
    func setPaused(_ paused: Bool) {
        frameRate.setPaused(paused)
    }

    /// 停到线程真正退出为止 —— 保证 `detach_surface` 之后不会再来一次 tick。
    func stop() {
        guard let thread else { return }
        self.thread = nil
        thread.cancel()
        if thread.waitUntilExited(timeout: 1.0) == .timedOut {
            // 线程还卡在 runloop 里没来得及退出：引用必须保住（挂进泄漏池），
            // 释放一个 main() 还在跑的 Thread 有崩溃风险。cancel 已发出，
            // 它最迟在下一个 runloop 唤醒点自行退出，这里只是不让它提前释放。
            Self.leakPool.add(thread)
        }
    }

    /// 等不到退出的渲染线程的"泄漏池"。正常退出路径（cancel 后 ≤50ms）走不到。
    private static let leakPool = LeakPool()

    private final class LeakPool: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [RenderThread] = []
        func add(_ thread: RenderThread) {
            lock.lock()
            threads.append(thread)
            lock.unlock()
        }
    }
}

/// 帧率档位的共享开关：写在任意线程，读和真正落到 `CADisplayLink` 都在渲染线程。
/// `CADisplayLink` 不是线程安全的，所以只在 `TickProxy.step` 里改它。
private final class FrameRatePolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var applied: Bool?
    private var defaultRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)

    /// 渲染线程启动前在主线程调用一次。
    func prime(defaultRange: CAFrameRateRange) {
        lock.lock()
        self.defaultRange = defaultRange
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// 渲染线程每帧调用；档位没变就什么都不做。
    func applyIfNeeded(to link: CADisplayLink) {
        lock.lock()
        let desired = paused
        let needsApply = applied != desired
        if needsApply { applied = desired }
        let restore = defaultRange
        lock.unlock()
        guard needsApply else { return }
        // 暂停档位故意不压到个位数：暂停时拖窗口 / resize 仍要跟手。
        link.preferredFrameRateRange = desired
            ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            : restore
    }
}

/// `CADisplayLink` 的 target。单独一层是为了不让 `RenderLoop` 被 runloop 强引用。
private final class TickProxy: NSObject {
    private let tick: @Sendable (Double) -> Void
    private let frameRate: FrameRatePolicy

    init(tick: @escaping @Sendable (Double) -> Void, frameRate: FrameRatePolicy) {
        self.tick = tick
        self.frameRate = frameRate
        super.init()
    }

    @objc func step(_ link: CADisplayLink) {
        frameRate.applyIfNeeded(to: link)
        tick(link.targetTimestamp)
    }
}

/// 用 `Thread` 子类而不是 `Thread { }` 闭包：把非 `Sendable` 的 `CADisplayLink`
/// 放在存储属性里，避免 Swift 6 的闭包捕获检查。
private final class RenderThread: Thread {
    private let link: CADisplayLink
    private let proxy: TickProxy
    private let exited = DispatchSemaphore(value: 0)

    init(link: CADisplayLink, proxy: TickProxy) {
        self.link = link
        self.proxy = proxy
        super.init()
    }

    override func main() {
        link.add(to: .current, forMode: .default)
        while !isCancelled {
            // 带超时地跑，cancel 之后最迟 50 ms 退出。
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        link.invalidate()
        exited.signal()
    }

    @discardableResult
    func waitUntilExited(timeout: TimeInterval) -> DispatchTimeoutResult {
        exited.wait(timeout: .now() + timeout)
    }
}
