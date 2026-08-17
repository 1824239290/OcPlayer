import Foundation
import QuartzCore

#if os(macOS)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
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

    /// 必须在主线程调用（要摸视图；`NSView.displayLink` 本身就是 main actor 隔离的）。
    @MainActor
    func start(on view: PlatformView) {
        guard thread == nil, let onTick else { return }
        let proxy = TickProxy(tick: onTick)
        #if os(macOS)
        let link = view.displayLink(target: proxy, selector: #selector(TickProxy.step(_:)))
        #else
        let link = CADisplayLink(target: proxy, selector: #selector(TickProxy.step(_:)))
        #endif
        let thread = RenderThread(link: link, proxy: proxy)
        thread.name = "dev.jumusu.OcPlayer.render"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// 停到线程真正退出为止 —— 保证 `detach_surface` 之后不会再来一次 tick。
    func stop() {
        guard let thread else { return }
        self.thread = nil
        thread.cancel()
        thread.waitUntilExited(timeout: 1.0)
    }
}

/// `CADisplayLink` 的 target。单独一层是为了不让 `RenderLoop` 被 runloop 强引用。
private final class TickProxy: NSObject {
    private let tick: @Sendable (Double) -> Void

    init(tick: @escaping @Sendable (Double) -> Void) {
        self.tick = tick
        super.init()
    }

    @objc func step(_ link: CADisplayLink) {
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

    func waitUntilExited(timeout: TimeInterval) {
        _ = exited.wait(timeout: .now() + timeout)
    }
}
