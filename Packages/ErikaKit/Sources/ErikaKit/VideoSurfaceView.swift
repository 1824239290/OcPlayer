import QuartzCore
import SwiftUI

/// 承载视频画面的 SwiftUI 视图：内部是一个 layer-backed 原生视图，backing layer 直接就是
/// `CAMetalLayer`，指针交给内核（`attach_metal_layer`），像素尺寸 / scale 变化时补 `resize_surface`。
///
/// 若日后遇到与 SwiftUI 材质叠加、圆角裁剪或 resize 撕裂的问题，降级方案是把视频放到
/// 一个独立的 overlay window（控制层在上层窗口），见 PLAN.md 第四节。
public struct VideoSurfaceView: View {
    private let engine: ErikaEngine

    public init(engine: ErikaEngine) {
        self.engine = engine
    }

    public var body: some View {
        SurfaceRepresentable(engine: engine)
    }
}

/// 连续 surface resize 的合并器（主线程专用，两端共用）。
///
/// **为什么需要**：`resize_surface` 每改一次 viewport，内核就把弹幕全量重排一遍
/// （`danmaku_viewport_requires_relayout`，阈值 2px），屏上正在跑的弹幕会重新分行。
/// 而一次窗口尺寸变化在 AppKit/UIKit 里从来不是「一次」——`PlayerWindowFitter`
/// 的 `setFrame(display:animate:)` 会跑一段系统动画，实测按贴合幅度驱动
/// **12～20 次**布局回调（每步 6～44px，全部越过 2px 阈值），
/// 于是弹幕在几百毫秒里被连着重排十几次，看上去就是「弹幕突然跳位置」。
/// 全屏切换和拖窗口边是同一形状的问题。
///
/// **策略**：一串连续变化里第一次立刻应用（单次 resize 不该被拖慢），
/// 之后按 `interval` 节流，每档结束时按**最终几何**再应用一次。
/// 醒来时调用方重新读几何，所以中间值一个都不用留。实测 20 次 → 5 次。
///
/// 代价是变化期间 drawable 尺寸最多落后 layer bounds 一个 `interval`，
/// CoreAnimation 会把画面拉伸一点点——和任何播放器 resize 时的表现一样，
/// 比弹幕连着跳十几下划算得多。
///
/// ⚠️ 别想用 `inLiveResize` 把「用户拖窗口边」摘出来单独走即时路径：
/// 实测 `setFrame(display:animate:)` 的系统动画期间它同样是 true，区分不开。
struct SurfaceResizeCoalescer {
    /// 节流档位。10Hz 的 surface 更新对拖动 / 动画都跟得上，
    /// 又把全量重排的次数压到原来的几分之一。
    private static let interval: CFTimeInterval = 0.1

    private var lastAppliedAt: CFTimeInterval = 0
    private var pending: DispatchWorkItem?

    /// 距上次应用还不到一档 → 说明正在一串连续变化里。
    func shouldDefer() -> Bool {
        CACurrentMediaTime() - lastAppliedAt < Self.interval
    }

    /// 排一次延后落地。已经排过就不重复排——那一个醒来时会读到最新几何。
    mutating func schedule(_ apply: @escaping () -> Void) {
        guard pending == nil else { return }
        let item = DispatchWorkItem(block: apply)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval, execute: item)
    }

    mutating func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    mutating func markApplied() {
        lastAppliedAt = CACurrentMediaTime()
    }
}

#if os(macOS)
private struct SurfaceRepresentable: NSViewRepresentable {
    let engine: ErikaEngine

    func makeNSView(context: Context) -> MetalHostView {
        MetalHostView(engine: engine)
    }

    func updateNSView(_ view: MetalHostView, context: Context) {
        view.syncSurface()
    }

    static func dismantleNSView(_ view: MetalHostView, coordinator: ()) {
        view.teardown()
    }
}

final class MetalHostView: NSView {
    private let engine: ErikaEngine
    private var attached = false
    /// `teardown()` 之后为 true，`syncSurface` 一律短路。
    /// 合并器让 resize 变成异步落地，没有这道闸的话一次迟到的 syncSurface
    /// 会走进 `!attached` 分支、对着已经 detach 的 surface 重新 attach。
    private var torndown = false
    /// 已经交给内核的尺寸 / scale（不是「最近观察到的」——中间被合并掉的那些不算）。
    private var appliedPixelSize: CGSize = .zero
    private var appliedScale: CGFloat = 0
    private var coalescer = SurfaceResizeCoalescer()

    init(engine: ErikaEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不走 xib") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        // 首帧到达前 CAMetalLayer 的内容是未初始化的 framebuffer（macOS 上呈现为白色）。
        // 垫一层黑：首帧前的窗口期露出来的是黑，和 loading/画面连续，不白闪。
        layer.backgroundColor = NSColor.black.cgColor
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSurface()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurface()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurface()
    }

    override func layout() {
        super.layout()
        syncSurface()
    }

    /// 第一次有窗口且有尺寸时 attach，之后只做 resize。
    ///
    /// **连续变化会被合并**，原因见 `SurfaceResizeCoalescer`：一次窗口贴合动画
    /// （`PlayerWindowFitter` 的 `setFrame(animate: true)`）实测会驱动十几次布局，
    /// 每次都传给内核就是一次弹幕全量重排，屏上的弹幕会连着跳十几下。
    func syncSurface() {
        guard !torndown, let metalLayer, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixel = CGSize(width: (bounds.width * scale).rounded(),
                           height: (bounds.height * scale).rounded())
        guard pixel.width >= 1, pixel.height >= 1 else { return }
        // 内核 viewport 重排阈值是 >=2px（danmaku_viewport_requires_relayout）。
        // 视图 bounds 微抖动会 1px 级变化，用同样的阈值挡掉，别去打扰弹幕布局。
        let deltaX = abs(pixel.width - appliedPixelSize.width)
        let deltaY = abs(pixel.height - appliedPixelSize.height)
        let scaleChanged = scale != appliedScale
        guard deltaX >= 2 || deltaY >= 2 || scaleChanged else { return }

        // 只有这两种必须立刻生效，不能压着等：
        // - 还没 attach：那是出首帧的前提
        // - DPI 变了（挪到另一块屏）：晚一拍整帧都按错的密度渲染
        //
        // 注意**不要**在这里加 `inLiveResize` 例外把用户拖拽放过去。实测
        // `setFrame(display:animate:)` 的系统动画期间 `inLiveResize` 同样是 true
        // （20 步里 18 步 live=true），拿它区分「用户拖拽 / 程序化动画」区分不开，
        // 加了这个例外等于把合并整个绕过去。
        if !attached || scaleChanged {
            applyNow(metalLayer, pixel: pixel, scale: scale)
            return
        }

        // 连续变化（窗口贴合动画、全屏切换、拖窗口边）：登记一次，等这一档
        // 合并窗口结束后按**最终几何**应用。醒来时重新读几何，中间值全部不用记。
        if coalescer.shouldDefer() {
            coalescer.schedule { [weak self] in self?.syncSurface() }
            return
        }
        applyNow(metalLayer, pixel: pixel, scale: scale)
    }

    private func applyNow(_ metalLayer: CAMetalLayer, pixel: CGSize, scale: CGFloat) {
        coalescer.cancelPending()
        coalescer.markApplied()
        appliedPixelSize = pixel
        appliedScale = scale
        metalLayer.contentsScale = scale

        if attached {
            engine.resize(pixelWidth: Int(pixel.width), pixelHeight: Int(pixel.height), scale: scale)
        } else {
            do {
                try engine.attach(to: self, layer: metalLayer,
                                  pixelWidth: Int(pixel.width), pixelHeight: Int(pixel.height),
                                  scale: scale)
                attached = true
            } catch {
                // attach 失败就保持未挂载，下一次 layout 再试；错误细节由 events 流报出。
                appliedPixelSize = .zero
            }
        }
    }

    func teardown() {
        // 先撤掉待落地的 resize：detach 之后再 resize 就是摸已经拆掉的 surface。
        coalescer.cancelPending()
        torndown = true
        guard attached else { return }
        attached = false
        engine.detach()
    }
}

#else

private struct SurfaceRepresentable: UIViewRepresentable {
    let engine: ErikaEngine

    func makeUIView(context: Context) -> MetalHostView {
        MetalHostView(engine: engine)
    }

    func updateUIView(_ view: MetalHostView, context: Context) {
        view.syncSurface()
    }

    static func dismantleUIView(_ view: MetalHostView, coordinator: ()) {
        view.teardown()
    }
}

final class MetalHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let engine: ErikaEngine
    private var attached = false
    /// `teardown()` 之后为 true，`syncSurface` 一律短路。
    /// 合并器让 resize 变成异步落地，没有这道闸的话一次迟到的 syncSurface
    /// 会走进 `!attached` 分支、对着已经 detach 的 surface 重新 attach。
    private var torndown = false
    /// 已经交给内核的尺寸 / scale（不是「最近观察到的」）。
    private var appliedPixelSize: CGSize = .zero
    private var appliedScale: CGFloat = 0
    private var coalescer = SurfaceResizeCoalescer()

    init(engine: ErikaEngine) {
        self.engine = engine
        super.init(frame: .zero)
        isOpaque = true
        // 同 macOS：首帧前垫黑，避免未初始化内容白闪。
        (layer as? CAMetalLayer)?.isOpaque = true
        (layer as? CAMetalLayer)?.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不走 xib") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncSurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSurface()
    }

    /// 连续变化会被合并，原因见 `SurfaceResizeCoalescer`。
    /// iPad 上分屏拖拽 / 旋转同样是一串连续布局，不合并就是一串弹幕重排。
    func syncSurface() {
        guard !torndown, let metalLayer = layer as? CAMetalLayer, window != nil else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixel = CGSize(width: (bounds.width * scale).rounded(),
                           height: (bounds.height * scale).rounded())
        guard pixel.width >= 1, pixel.height >= 1 else { return }
        // 同 macOS：内核 viewport 重排阈值 >=2px，微抖动不去抖会触发全量重排。
        let deltaX = abs(pixel.width - appliedPixelSize.width)
        let deltaY = abs(pixel.height - appliedPixelSize.height)
        let scaleChanged = scale != appliedScale
        guard deltaX >= 2 || deltaY >= 2 || scaleChanged else { return }

        // 未 attach（出首帧的前提）和 DPI 变化必须立刻生效，不能压着等。
        if !attached || scaleChanged {
            applyNow(metalLayer, pixel: pixel, scale: scale)
            return
        }
        if coalescer.shouldDefer() {
            coalescer.schedule { [weak self] in self?.syncSurface() }
            return
        }
        applyNow(metalLayer, pixel: pixel, scale: scale)
    }

    private func applyNow(_ metalLayer: CAMetalLayer, pixel: CGSize, scale: CGFloat) {
        coalescer.cancelPending()
        coalescer.markApplied()
        appliedPixelSize = pixel
        appliedScale = scale
        metalLayer.contentsScale = scale

        if attached {
            engine.resize(pixelWidth: Int(pixel.width), pixelHeight: Int(pixel.height), scale: scale)
        } else {
            do {
                try engine.attach(to: self, layer: metalLayer,
                                  pixelWidth: Int(pixel.width), pixelHeight: Int(pixel.height),
                                  scale: scale)
                attached = true
            } catch {
                appliedPixelSize = .zero
            }
        }
    }

    func teardown() {
        // 先撤掉待落地的 resize：detach 之后再 resize 就是摸已经拆掉的 surface。
        coalescer.cancelPending()
        torndown = true
        guard attached else { return }
        attached = false
        engine.detach()
    }
}
#endif
