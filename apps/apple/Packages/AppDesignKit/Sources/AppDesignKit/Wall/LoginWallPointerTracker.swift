import SwiftUI

#if canImport(AppKit)
import AppKit

/// 上报窗口内指针的位置，归一化到 −1...1。
///
/// ## 为什么用 `NSTrackingArea` 而不是 SwiftUI 的 `onContinuousHover`
///
/// 上一版实测 `onContinuousHover` 在这个形态下**一次都没触发过**——真实鼠标移动和
/// 合成事件都不行。`NSTrackingArea` 是 AppKit 自己做这件事的方式，而且它把决定
/// 「鼠标移动事件到不到」的两件事写得很明确：区域必须带 `.mouseMoved`，且窗口必须是
/// key window。
///
/// 视图透明、`hitTest` 返回 `nil`，所以它可以压在墙上面而**不拦截登录卡的点击**。
///
/// 这里**不做**节流（试过把上报合并到显示器刷新率）：墙改成「一张合成图 + 变换」之后，
/// 单次上报已经便宜到节流只会多一层延迟，实测也拿不到任何 CPU 收益。
public struct LoginWallPointerTracker: View {
    /// 归一化位置；指针离开窗口时收到 `nil`。
    public let onChange: (CGPoint?) -> Void

    public init(onChange: @escaping (CGPoint?) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        LoginWallPointerRepresentable(onChange: onChange)
    }
}

private struct LoginWallPointerRepresentable: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> LoginWallPointerTrackerView {
        let view = LoginWallPointerTrackerView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: LoginWallPointerTrackerView, context: Context) {
        nsView.onChange = onChange
    }
}

final class LoginWallPointerTrackerView: NSView {
    var onChange: ((CGPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    /// 对命中测试透明：登录卡和它的按钮必须照常工作，这个视图只是来观察的。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onChange?(nil) }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // AppKit 原点在左下，翻过来让 −1 是上边缘——倾斜的算式按这个约定写。
        let x = (point.x / bounds.width) * 2 - 1
        let y = (point.y / bounds.height) * 2 - 1
        onChange?(CGPoint(x: clamp(x), y: clamp(y)))
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, -1), 1)
    }
}

#else

/// iOS 没有指针，「鼠标移动 → 墙倾斜」这条输入路径不存在。
///
/// 这里**刻意不做陀螺仪 / 触摸视差**：登录页是静止的一屏，加一条只在晃动手机时
/// 才看得见的动效，收益远小于它带来的传感器订阅与耗电。墙在 iOS 上是一张静态图。
public struct LoginWallPointerTracker: View {
    public let onChange: (CGPoint?) -> Void

    public init(onChange: @escaping (CGPoint?) -> Void) {
        self.onChange = onChange
    }

    public var body: some View { EmptyView() }
}

#endif
