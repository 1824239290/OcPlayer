import SwiftUI

#if os(iOS)
import UIKit

/// SwiftUI 的 zoom 没有交互关闭开关。只在当前详情宿主上裁决竖向下拉，
/// 将第二页的这次拖动交还给正文 ScrollView；其余系统手势保留原代理的判断。
struct DetailZoomDismissGuard: UIViewRepresentable {
    let blocked: Bool

    func makeUIView(context: Context) -> GuardView { GuardView() }

    func updateUIView(_ uiView: GuardView, context: Context) {
        uiView.blocked = blocked
        uiView.bind()
        DispatchQueue.main.async { uiView.bind() }
    }

    static func dismantleUIView(_ uiView: GuardView, coordinator: ()) {
        uiView.unbind()
    }

    final class GuardView: UIView {
        var blocked = false
        private var proxies: [PanDelegate] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { unbind() }
            else { DispatchQueue.main.async { self.bind() } }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            bind()
        }

        func bind() {
            guard window != nil else { return }
            proxies.removeAll { $0.pan == nil || $0.pan?.delegate !== $0 }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   controller.preferredTransition != nil {
                    for gesture in controller.view.gestureRecognizers ?? [] {
                        guard let pan = gesture as? UIPanGestureRecognizer else { continue }
                        if proxies.contains(where: { $0.pan === pan && pan.delegate === $0 }) { continue }
                        let proxy = PanDelegate(pan: pan, original: pan.delegate, guardView: self)
                        proxies.append(proxy)
                        pan.delegate = proxy
                    }
                    return
                }
                responder = current.next
            }
        }

        func unbind() {
            for proxy in proxies where proxy.pan?.delegate === proxy {
                proxy.pan?.delegate = proxy.original
            }
            proxies.removeAll()
        }
    }

    final class PanDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var pan: UIPanGestureRecognizer?
        weak var original: (any UIGestureRecognizerDelegate)?
        weak var guardView: GuardView?

        init(pan: UIPanGestureRecognizer, original: (any UIGestureRecognizerDelegate)?, guardView: GuardView) {
            self.pan = pan
            self.original = original
            self.guardView = guardView
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if guardView?.blocked == true, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: pan.view)
                if velocity.y > abs(velocity.x) { return false }
            }
            return original?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
        }
    }
}

#endif

extension EnvironmentValues {
    @Entry var detailZoomNamespace: Namespace.ID? = nil
}

extension View {
    func detailZoomSource(id: String) -> some View {
        modifier(DetailZoomSourceModifier(sourceID: id))
    }

    func detailZoomDestination(itemID: String) -> some View {
        modifier(DetailZoomDestinationModifier(itemID: itemID))
    }
}

private struct DetailZoomSourceModifier: ViewModifier {
    let sourceID: String
    @Environment(\.detailZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone, !reduceMotion, let namespace {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct DetailZoomDestinationModifier: ViewModifier {
    let itemID: String
    @Environment(AppModel.self) private var app
    @Environment(\.detailZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone, !reduceMotion,
           let namespace, let sourceID = app.detailZoomSourceIDs[itemID] {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
