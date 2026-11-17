#if os(iOS)
import SwiftUI
import JellyfinKit
import CoreModel
import UIKit
import XCTest
@testable import OcPlayer

@MainActor
final class TabBarBrandIconBridgeTests: XCTestCase {
    private func avatar(_ color: UIColor = .systemPink) -> UIImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return AppModel.tabIcon(from: image)
    }

    private func saturation(_ image: UIImage?) throws -> Double {
        let cgImage = try XCTUnwrap(image?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let maximum = Double(pixel.prefix(3).max()!)
        let minimum = Double(pixel.prefix(3).min()!)
        return maximum == 0 ? 0 : (maximum - minimum) / maximum
    }

    private func fixture() -> (UIViewController, UITabBarController, UITab, TabBarBrandIconController) {
        let root = UIViewController()
        let controller = UITabBarController()
        let home = UITab(title: "首页", image: avatar(), identifier: "home") { _ in UIViewController() }
        let settings = UITab(title: "设置", image: UIImage(systemName: "gearshape"), identifier: "settings") { _ in UIViewController() }
        controller.tabs = [home, settings]
        controller.loadViewIfNeeded()
        root.addChild(controller)
        controller.didMove(toParent: root)
        let bridge = TabBarBrandIconController()
        bridge.avatar = home.image
        root.addChild(bridge)
        bridge.didMove(toParent: root)
        bridge.apply()
        return (root, controller, home, bridge)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    func testWritesGraySourceAndColorSelectedImage() throws {
        let (root, controller, home, bridge) = fixture()
        defer { bridge.stopObserving(); _ = root }
        XCTAssertLessThan(try saturation(home.image), 0.05)
        #if compiler(>=6.4)
        if #available(iOS 26.1, *) {
            XCTAssertGreaterThan(try saturation(home.selectedImage), 0.5)
        }
        #endif
        let item = try XCTUnwrap(controller.tabBar.items?.first)
        XCTAssertLessThan(try saturation(item.image), 0.05)
        XCTAssertGreaterThan(try saturation(item.selectedImage), 0.5)
    }

    /// 模拟 SwiftUI 在桥接更新完成之后，把同一个栏项的灰图重置为彩色。
    func testRepairsLateItemOverwriteWithoutAnotherSwiftUIUpdate() async throws {
        let (root, controller, _, bridge) = fixture()
        defer { bridge.stopObserving(); _ = root }
        let item = try XCTUnwrap(controller.tabBar.items?.first)
        item.image = avatar()
        item.selectedImage = nil
        try await settle()
        XCTAssertLessThan(try saturation(item.image), 0.05)
        XCTAssertGreaterThan(try saturation(item.selectedImage), 0.5)
    }

    func testRepairsSourceOverwriteAndRecreatedTabs() async throws {
        let (root, controller, home, bridge) = fixture()
        defer { bridge.stopObserving(); _ = root }
        home.image = avatar(.systemOrange)
        try await settle()
        XCTAssertLessThan(try saturation(home.image), 0.05)
        let replacement = UITab(title: "首页", image: avatar(), identifier: "new-home") { _ in UIViewController() }
        controller.tabs = [replacement, controller.tabs[1]]
        try await settle()
        XCTAssertLessThan(try saturation(replacement.image), 0.05)
        XCTAssertLessThan(try saturation(controller.tabBar.items?.first?.image), 0.05)
    }

    func testAccountAvatarChangeRefreshesBothStatesAndLeavesSettingsAlone() async throws {
        let (root, controller, home, bridge) = fixture()
        defer { bridge.stopObserving(); _ = root }
        let settingsImage = controller.tabs[1].image
        let replacement = avatar(.systemGreen)
        bridge.avatar = replacement
        bridge.apply()
        bridge.selectedSection = .settings
        bridge.apply()
        controller.selectedTab = controller.tabs[1]
        try await settle()
        XCTAssertLessThan(try saturation(home.image), 0.05)
        #if compiler(>=6.4)
        if #available(iOS 26.1, *) {
            XCTAssertLessThan(try saturation(home.selectedImage), 0.05)
        }
        #endif
        bridge.selectedSection = .home
        bridge.apply()
        #if compiler(>=6.4)
        if #available(iOS 26.1, *) {
            XCTAssertEqual(home.selectedImage?.pngData(), replacement.pngData())
        }
        #endif
        XCTAssertEqual(controller.tabBar.items?.first?.selectedImage?.pngData(), replacement.pngData())
        XCTAssertEqual(controller.tabs[1].image?.pngData(), settingsImage?.pngData())
    }

    func testDismantledBridgeStopsRepairing() async throws {
        let (root, controller, _, bridge) = fixture()
        defer { _ = root }
        bridge.scheduleApply()
        bridge.stopObserving()
        let item = try XCTUnwrap(controller.tabBar.items?.first)
        item.image = avatar()
        try await settle()
        XCTAssertGreaterThan(try saturation(item.image), 0.5)
    }
}

/// 用生产 AppShell 检查搜索与桥接层，而不是在测试里复刻 TabView 配置。
@MainActor
final class TabSearchIntegrationTests: XCTestCase {
    private func findTabController(_ root: UIViewController) -> UITabBarController? {
        if let controller = root as? UITabBarController { return controller }
        for child in root.children {
            if let controller = findTabController(child) { return controller }
        }
        return nil
    }

    private func findNavigation(_ root: UIViewController) -> UINavigationController? {
        if let navigation = root as? UINavigationController { return navigation }
        return root.children.compactMap { findNavigation($0) }.first
    }

    /// A fixed delay can expire in the middle of UIKit's tab/navigation transition.
    /// Wait for the selected stack and visibility together; a permanent mismatch still fails.
    private func waitForTabState(_ controller: UITabBarController, title: String,
                                 depth: Int, hidden: Bool) async throws {
        let index = try XCTUnwrap(controller.tabBar.items?.firstIndex { $0.title == title })
        func ready() -> Bool {
            guard controller.selectedIndex == index,
                  let selected = controller.selectedViewController,
                  let navigation = findNavigation(selected) else { return false }
            return selected.viewIfLoaded?.window != nil
                && navigation.viewControllers.count == depth
                && controller.transitionCoordinator == nil
                && navigation.transitionCoordinator == nil
                && controller.isTabBarHidden == hidden
        }
        let deadline = Date().addingTimeInterval(3)
        var settledFrames = 0
        while Date() < deadline, settledFrames < 2 {
            settledFrames = ready() ? settledFrames + 1 : 0
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(settledFrames == 2 && ready(),
                      "\(title) must settle at depth \(depth), hidden=\(hidden); selected=\(controller.selectedIndex), hidden=\(controller.isTabBarHidden)")
    }

    func testProductionTabBarSurvivesDetailReturnAndSearchSelection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TabSearchIntegrationTests-\(UUID())"))
        let app = AppModel(store: ServerStore(defaults: defaults, tokens: InMemoryTokenStore()), preferences: defaults)
        let colored = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        app.userAvatarImage = AppModel.tabIcon(from: colored)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: AppShellView()
            .environment(app)
            .environment(app.bangumi)
            .environment(app.moviepilot)
            .environment(app.danmakuModel))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        let controller = try XCTUnwrap(findTabController(try XCTUnwrap(window.rootViewController)))
        XCTAssertEqual(controller.tabBar.items?.compactMap(\.title), ["首页", "观影", "设置", "搜索"])
        XCTAssertTrue(app.openMoviePilot())
        try await waitForTabState(controller, title: "观影", depth: 2, hidden: false)
        XCTAssertEqual(app.navPath(for: .my), [.moviepilotHome])
        app.back()
        try await waitForTabState(controller, title: "观影", depth: 1, hidden: false)
        app.selectedSection = .home
        try await waitForTabState(controller, title: "首页", depth: 1, hidden: false)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        app.setNavPath([.detail(MediaItem(id: "tab-return", name: "返回验收", kind: .movie))], for: .home)
        try await waitForTabState(controller, title: "首页", depth: 2, hidden: phone)
        XCTAssertEqual(controller.isTabBarHidden, phone, "iPhone 详情隐藏标签栏，iPad 详情保留标签栏")
        app.selectedSection = .settings
        try await waitForTabState(controller, title: "设置", depth: 1, hidden: false)
        XCTAssertFalse(controller.isTabBarHidden, "切到其他 Tab 的根页必须显示标签栏")
        app.selectedSection = .home
        try await waitForTabState(controller, title: "首页", depth: 2, hidden: phone)
        XCTAssertEqual(controller.isTabBarHidden, phone)
        app.back()
        try await waitForTabState(controller, title: "首页", depth: 1, hidden: false)
        XCTAssertFalse(controller.isTabBarHidden, "从详情返回必须恢复标签栏")
        func searchControllers(_ root: UIViewController) -> [UISearchController] {
            let own = root.navigationItem.searchController.map { [$0] } ?? []
            return own + root.children.flatMap { searchControllers($0) }
        }
        let items = try XCTUnwrap(controller.tabBar.items)
        let searchIndex = try XCTUnwrap(items.firstIndex { $0.title == "搜索" })
        let home = try XCTUnwrap(items.first { $0.title == "首页" })
        XCTAssertEqual(home.image?.renderingMode, .alwaysOriginal)
        XCTAssertNotEqual(home.image?.pngData(), app.userAvatarImage?.pngData(), "栏项图片必须是灰化版本")
        func attach(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertFalse(searchControllers(controller).contains { $0.searchBar.window != nil }, "首页不应出现全库搜索框")
        attach("independent-search-home")
        app.selectedSection = .search
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(app.selectedSection, .search)
        XCTAssertEqual(controller.selectedIndex, searchIndex)
        // iPhone 的搜索框会由系统搬到标签栏，原 UISearchBar 不一定仍挂在窗口里。
        // 检查用户实际能操作的输入框，而不是它原来的导航栏宿主。
        func visibleSearchField(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField,
               field.placeholder == "搜索全部媒体库", field.window != nil { return field }
            return view.subviews.compactMap { visibleSearchField($0) }.first
        }
        XCTAssertNotNil(visibleSearchField(window), "搜索页必须有可操作的搜索输入框")
        XCTAssertNotEqual(home.selectedImage?.pngData(), app.userAvatarImage?.pngData(), "进入搜索时首页头像也应去色")
        attach("independent-search-page")
        app.selectedSection = .settings
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(app.selectedSection, .settings)
        let item = try XCTUnwrap(controller.tabBar.items?.first { $0.title == "首页" })
        XCTAssertNotEqual(item.image?.pngData(), app.userAvatarImage?.pngData(), "切换到其他 Tab 后头像仍应去色")
        XCTAssertNotEqual(item.selectedImage?.pngData(), app.userAvatarImage?.pngData(), "搜索收起态也可能使用 selectedImage，未选中时这张也必须灰化")
        app.selectedSection = .home
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(item.selectedImage?.pngData(), app.userAvatarImage?.pngData())
    }
}
#endif
