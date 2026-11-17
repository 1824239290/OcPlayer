#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import OcPlayer

@MainActor
final class DetailTabBarVisibilityTests: XCTestCase {
    func testWritesNavigationPageFlagWithoutChangingOtherPages() {
        let root = UIViewController()
        let detail = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(detail, animated: false)
        let bridge = DetailTabBarVisibilityController()
        detail.addChild(bridge)
        bridge.didMove(toParent: detail)
        bridge.isHidden = true
        bridge.apply()
        XCTAssertTrue(detail.hidesBottomBarWhenPushed)
        XCTAssertFalse(root.hidesBottomBarWhenPushed)
        bridge.isHidden = false
        bridge.apply()
        XCTAssertFalse(detail.hidesBottomBarWhenPushed)
    }

    func testSwiftUIZoomReturnRestoresTabBarDuringNavigationTransition() async throws {
        try await assertReturn(zoom: true)
    }

    func testSwiftUISlideReturnRestoresTabBarDuringNavigationTransition() async throws {
        try await assertReturn(zoom: false)
    }

    func testCancelledInteractiveReturnKeepsDetailAndHiddenTabBar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let tab = UITabBarController()
        tab.viewControllers = [navigation]
        window.rootViewController = tab
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        func attach(_ hidden: Bool, to page: UIViewController) {
            let bridge = DetailTabBarVisibilityController()
            bridge.isHidden = hidden
            page.addChild(bridge)
            page.view.addSubview(bridge.view)
            bridge.didMove(toParent: page)
        }
        attach(false, to: root)
        let detail = UIViewController()
        attach(true, to: detail)
        navigation.pushViewController(detail, animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(tab.isTabBarHidden)
        let driver = TabBarInteractivePopDriver()
        navigation.delegate = driver
        navigation.popViewController(animated: true)
        driver.interaction.update(0.4)
        try await Task.sleep(for: .milliseconds(80))
        driver.interaction.cancel()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(navigation.topViewController === detail)
        XCTAssertTrue(tab.isTabBarHidden, "取消交互式返回后，详情页的标签栏必须仍然隐藏")
    }

    private func assertReturn(zoom: Bool) async throws {
        let state = TabBarNavigationState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: TabBarNavigationFixture(state: state, zoom: zoom))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(200))
        let tab = try XCTUnwrap(find(UITabBarController.self, in: host))
        let navigation = try XCTUnwrap(find(UINavigationController.self, in: host))
        state.path = [1]
        try await Task.sleep(for: .milliseconds(800))
        let detail = try XCTUnwrap(navigation.topViewController)
        XCTAssertTrue(detail.hidesBottomBarWhenPushed)
        XCTAssertFalse(isVisible(tab.tabBar, in: window), "详情页必须隐藏标签栏")
        let start = CACurrentMediaTime()
        state.path = []
        var firstVisible: Double?
        var transitionEnd: Double?
        for _ in 0..<70 {
            try await Task.sleep(for: .milliseconds(16))
            let now = CACurrentMediaTime() - start
            if firstVisible == nil, isVisible(tab.tabBar, in: window) { firstVisible = now }
            if transitionEnd == nil, navigation.viewControllers.count == 1,
               navigation.transitionCoordinator == nil { transitionEnd = now }
            if firstVisible != nil, transitionEnd != nil { break }
        }
        print("TAB RETURN firstVisible=\(String(describing: firstVisible)) transitionEnd=\(String(describing: transitionEnd))")
        XCTAssertNotNil(firstVisible)
        XCTAssertNotNil(transitionEnd)
        if let firstVisible, let transitionEnd {
            XCTAssertLessThanOrEqual(firstVisible, transitionEnd + 0.05,
                "标签栏应随返回转场恢复，不能等页面返回结束才开始显示")
        }
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, (current.layer.presentation()?.opacity ?? Float(current.alpha)) > 0.05 else { return false }
            ancestor = current.superview
        }
        let layer = view.layer.presentation() ?? view.layer
        let rect = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
        return rect.intersection(window.bounds).height > 8 && layer.opacity > 0.05
    }

    private func find<T: UIViewController>(_ type: T.Type, in root: UIViewController) -> T? {
        if let result = root as? T { return result }
        return root.children.compactMap { find(type, in: $0) }.first
    }
}

@MainActor
@Observable
private final class TabBarNavigationState {
    var path: [Int] = []
}

private struct TabBarNavigationFixture: View {
    @Namespace private var namespace
    @Bindable var state: TabBarNavigationState
    let zoom: Bool

    var body: some View {
        TabView {
            Tab("首页", systemImage: "house") {
                NavigationStack(path: $state.path) {
                    Text("详情封面").frame(width: 200, height: 200)
                        .navigationTabBarHidden(false)
                        .matchedTransitionSource(id: 1, in: namespace)
                        .navigationDestination(for: Int.self) { _ in
                            if zoom {
                                Color.blue.navigationTabBarHidden(true)
                                    .navigationTransition(.zoom(sourceID: 1, in: namespace))
                            } else {
                                Color.blue.navigationTabBarHidden(true)
                            }
                        }
                }
            }
            Tab("设置", systemImage: "gearshape") { Text("设置") }
        }
    }
}

@MainActor
private final class TabBarInteractivePopDriver: NSObject, UINavigationControllerDelegate {
    let interaction = UIPercentDrivenInteractiveTransition()

    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController)
        -> (any UIViewControllerAnimatedTransitioning)? {
        TabBarPopAnimator()
    }

    func navigationController(_ navigationController: UINavigationController,
                              interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning)
        -> (any UIViewControllerInteractiveTransitioning)? {
        interaction
    }
}

@MainActor
private final class TabBarPopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.35 }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let from = context.viewController(forKey: .from), let to = context.viewController(forKey: .to) else { return }
        context.containerView.insertSubview(to.view, belowSubview: from.view)
        to.view.frame = context.finalFrame(for: to)
        UIView.animate(withDuration: transitionDuration(using: context)) {
            from.view.transform = CGAffineTransform(translationX: context.containerView.bounds.width, y: 0)
        } completion: { _ in
            context.completeTransition(!context.transitionWasCancelled)
            from.view.transform = .identity
        }
    }
}
#endif
