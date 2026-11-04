#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import OcPlayer

@MainActor
final class DetailNavigationDismissalTests: XCTestCase {
    func testGuardRestoresTransitionWithoutChangingBackGestures() {
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(page, animated: false)
        navigation.loadViewIfNeeded()
        let original = UIViewController.Transition.zoom(sourceViewProvider: { _ in nil })
        page.preferredTransition = original
        let guardController = attachGuard(to: page)
        let edge = navigation.interactivePopGestureRecognizer?.isEnabled
        let content = navigation.interactiveContentPopGestureRecognizer?.isEnabled

        guardController.isBlocked = true
        guardController.apply()
        XCTAssertNil(page.preferredTransition)
        guardController.apply()
        XCTAssertNil(page.preferredTransition)
        XCTAssertEqual(navigation.interactivePopGestureRecognizer?.isEnabled, edge)
        XCTAssertEqual(navigation.interactiveContentPopGestureRecognizer?.isEnabled, content)

        guardController.isBlocked = false
        guardController.apply()
        XCTAssertTrue(page.preferredTransition === original)
    }

    func testLeavingDetailRestoresItsTransitionWithoutOverwritingAnother() {
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: page)
        let original = UIViewController.Transition.zoom(sourceViewProvider: { _ in nil })
        page.preferredTransition = original
        let guardController = attachGuard(to: page)
        guardController.isBlocked = true
        guardController.apply()
        guardController.viewDidDisappear(false)
        XCTAssertTrue(page.preferredTransition === original)

        guardController.apply()
        let replacement = UIViewController.Transition.crossDissolve
        page.preferredTransition = replacement
        guardController.restore()
        XCTAssertTrue(page.preferredTransition === replacement)
        XCTAssertTrue(navigation.topViewController === page)
    }

    func testInactiveDetailDoesNotChangeTheNextNavigationPage() {
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: page)
        let original = UIViewController.Transition.zoom(sourceViewProvider: { _ in nil })
        page.preferredTransition = original
        let guardController = attachGuard(to: page)
        let next = UIViewController()
        navigation.pushViewController(next, animated: false)
        guardController.isBlocked = true
        guardController.apply()
        XCTAssertTrue(page.preferredTransition === original)
        XCTAssertNil(next.preferredTransition)
    }

    func testSwiftUIZoomHostGivesBodyPullToPagerAndRestoresCoverZoom() async throws {
        let state = NavigationFixtureState()
        state.pager.reduceMotion = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let host = UIHostingController(rootView: NavigationFixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            state.pager.reset()
        }
        try await waitUntil("创建导航宿主", host: host) { self.navigation(in: host) != nil }
        state.path = [1]
        try await waitUntil("进入缩放详情", host: host) {
            self.navigation(in: host)?.topViewController?.preferredTransition != nil
        }
        let navigation = try XCTUnwrap(navigation(in: host))
        let page = try XCTUnwrap(navigation.topViewController)
        let original = try XCTUnwrap(page.preferredTransition)
        let edgeEnabled = navigation.interactivePopGestureRecognizer?.isEnabled

        state.pager.flipToBody()
        try await waitUntil("正文暂停缩放返回", host: host) { page.preferredTransition == nil && !state.pager.isTransitioning }
        XCTAssertTrue(state.pager.blocksNavigationDismissal)
        state.pager.handleBodyScrollPhase(from: .idle, to: .tracking, offsetY: 0)
        state.pager.handleBodyScrollPhase(from: .tracking, to: .interacting, offsetY: -45)
        state.pager.handleBodyScrollPhase(from: .interacting, to: .idle, offsetY: -45)
        XCTAssertEqual(state.pager.page, .art)
        XCTAssertTrue(state.pager.blocksNavigationDismissal, "翻回封面的动画仍保护这一轮下拉")
        XCTAssertNil(page.preferredTransition)
        try await waitUntil("封面恢复缩放返回", host: host) { page.preferredTransition != nil && !state.pager.isTransitioning }
        XCTAssertFalse(state.pager.blocksNavigationDismissal)
        XCTAssertTrue(page.preferredTransition === original)
        XCTAssertTrue(navigation.topViewController === page, "内部下拉没有退出详情")
        XCTAssertEqual(navigation.interactivePopGestureRecognizer?.isEnabled, edgeEnabled)
    }

    private func attachGuard(to page: UIViewController) -> DetailNavigationDismissalController {
        let controller = DetailNavigationDismissalController()
        page.addChild(controller)
        page.view.addSubview(controller.view)
        controller.didMove(toParent: page)
        return controller
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let result = navigation(in: child) { return result }
        }
        return nil
    }

    private func waitUntil(_ stage: String, host: UIViewController, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("\(stage)超时：\(hierarchy(in: host))")
        throw NSError(domain: "DetailNavigationDismissalTests", code: 1)
    }

    private func hierarchy(in controller: UIViewController) -> String {
        "\(type(of: controller))[transition=\(String(describing: controller.preferredTransition))] {"
            + controller.children.map { hierarchy(in: $0) }.joined(separator: ", ") + "}"
    }
}

@MainActor
@Observable
private final class NavigationFixtureState {
    var path: [Int] = []
    let pager = DetailPagePager()
}

private struct NavigationFixture: View {
    @Namespace private var namespace
    @Bindable var state: NavigationFixtureState

    var body: some View {
        NavigationStack(path: $state.path) {
            NavigationLink(value: 1) { Text("封面卡片").frame(width: 200, height: 200) }
                .matchedTransitionSource(id: 1, in: namespace)
                .navigationDestination(for: Int.self) { _ in
                    Color.blue
                        .detailNavigationDismissalBlocked(state.pager.blocksNavigationDismissal)
                        .navigationTransition(.zoom(sourceID: 1, in: namespace))
                }
        }
    }
}
#endif
