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
    private var lastPixelSize: CGSize = .zero
    private var lastScale: CGFloat = 0

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
    func syncSurface() {
        guard let metalLayer, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixel = CGSize(width: (bounds.width * scale).rounded(),
                           height: (bounds.height * scale).rounded())
        guard pixel.width >= 1, pixel.height >= 1 else { return }
        // 内核 viewport 重排阈值是 >=2px（danmaku_viewport_requires_relayout）。
        // 视图 bounds 微抖动（HUD 出现/消失、拖拽、动画）会 1px 级变化，若精确比较
        // 会把这种抖动传给内核触发全量重排、弹幕跳行。这里用同样的 >=2px 阈值去抖：
        // 只有真实缩放才 resize，微抖动不打扰弹幕布局。
        let deltaX = abs(pixel.width - lastPixelSize.width)
        let deltaY = abs(pixel.height - lastPixelSize.height)
        guard deltaX >= 2 || deltaY >= 2 || scale != lastScale else { return }
        lastPixelSize = pixel
        lastScale = scale
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
                lastPixelSize = .zero
            }
        }
    }

    func teardown() {
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
    private var lastPixelSize: CGSize = .zero
    private var lastScale: CGFloat = 0

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

    func syncSurface() {
        guard let metalLayer = layer as? CAMetalLayer, window != nil else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixel = CGSize(width: (bounds.width * scale).rounded(),
                           height: (bounds.height * scale).rounded())
        guard pixel.width >= 1, pixel.height >= 1 else { return }
        // 同 macOS：内核 viewport 重排阈值 >=2px，微抖动不去抖会触发全量重排。
        let deltaX = abs(pixel.width - lastPixelSize.width)
        let deltaY = abs(pixel.height - lastPixelSize.height)
        guard deltaX >= 2 || deltaY >= 2 || scale != lastScale else { return }
        lastPixelSize = pixel
        lastScale = scale
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
                lastPixelSize = .zero
            }
        }
    }

    func teardown() {
        guard attached else { return }
        attached = false
        engine.detach()
    }
}
#endif
