#if os(iOS)

import AppDesignKit
import SwiftUI
import UIKit

/// 系统标签栏的品牌图标：选中彩色、未选中灰。
/// SwiftUI 的 Tab 只提供一张图片，所以同时维护 UITab 的图片源与
/// UITabBarItem 的两态图片。重建或回写后由 KVO 合并到下一轮主队列修复。
struct TabBarBrandIconBridge: UIViewControllerRepresentable {
    let avatar: PlatformImage?
    let selectedSection: AppModel.Section

    func makeUIViewController(context: Context) -> TabBarBrandIconController {
        let controller = TabBarBrandIconController()
        controller.avatar = avatar
        controller.selectedSection = selectedSection
        return controller
    }

    func updateUIViewController(_ controller: TabBarBrandIconController, context: Context) {
        controller.avatar = avatar
        controller.selectedSection = selectedSection
        controller.apply()
        controller.scheduleApply()
    }

    static func dismantleUIViewController(_ controller: TabBarBrandIconController, coordinator: ()) {
        controller.stopObserving()
    }
}

/// 要接管的标签栏槽位。**按标题匹配** —— 整条路唯一脆的地方，所以抽成纯函数用单例钉住。
///
/// 为什么不用下标 / 标识：SwiftUI 的 `Tab` 没有给 `UITabBarItem` 打标识的 API，能稳定拿到
/// 的只有标题。当前主导航只使用首页头像；保留旧品牌槽位的渲染支持供兼容与回归使用，
/// 其完整页面已归入「观影」。观影 / 设置 / 搜索等系统图标不接管。
enum TabBarBrandSlot: String, CaseIterable {
    case home = "首页"
    case bangumi = "Bangumi"
    case moviepilot = "MoviePilot"

    static func slot(forTitle title: String) -> TabBarBrandSlot? {
        TabBarBrandSlot(rawValue: title)
    }
}

/// 真正干活的那一层：找标签栏、换 icon、缓存灰化后的头像。
final class TabBarBrandIconController: UIViewController {
    /// 搜索展开时系统会用上一页的 selectedImage 画返回按钮；以实际分区决定颜色。
    var selectedSection: AppModel.Section = .home
    /// 当前账号头像（已经烤成标签栏版本）。换图时才需要重烤灰色那张。
    var avatar: UIImage? {
        didSet {
            if avatar !== oldValue { grayAvatar = nil }
        }
    }

    private var grayAvatar: UIImage?
    private weak var observedTabBarController: UITabBarController?
    private var containerObservations: [NSKeyValueObservation] = []
    private var imageObservations: [NSKeyValueObservation] = []
    private var isApplying = false
    private var applyScheduled = false
    private var isStopped = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
        scheduleApply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 初次挂载或宿主替换时重连；没有固定间隔的轮询。
        if Self.findTabBarController(from: self) !== observedTabBarController {
            scheduleApply()
        }
    }

    func scheduleApply() {
        guard !isStopped, !isApplying, !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.apply()
        }
    }

    func stopObserving() {
        isStopped = true
        containerObservations.removeAll()
        imageObservations.removeAll()
        observedTabBarController = nil
    }

    /// 维护 UITab 源与栏项两层：只改栏项时，UIKit 可以从彩色源重新生成它。
    func apply() {
        guard !isStopped, !isApplying,
              let controller = Self.findTabBarController(from: self) else { return }
        isApplying = true
        defer { isApplying = false }
        observe(controller)
        imageObservations.removeAll()

        for tab in controller.tabs {
            guard let slot = TabBarBrandSlot.slot(forTitle: tab.title),
                  let images = images(for: slot) else { continue }
            let selectedImage = selectedImage(for: slot, images: images)
            imageObservations.append(tab.observe(\.image) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            })
            // 该属性在 Xcode 27 SDK 才公开，虽标记为可回部署到 iOS 26.1。
            #if compiler(>=6.4)
            if #available(iOS 26.1, *) {
                imageObservations.append(tab.observe(\.selectedImage) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleApply() }
                })
                if !Self.sameImage(tab.selectedImage, selectedImage) {
                    tab.selectedImage = selectedImage
                }
            }
            #endif
            if !Self.sameImage(tab.image, images.unselected) {
                tab.image = images.unselected
            }
        }

        for item in controller.tabBar.items ?? [] {
            guard let slot = TabBarBrandSlot.slot(forTitle: item.title ?? ""),
                  let images = images(for: slot) else { continue }
            let selectedImage = selectedImage(for: slot, images: images)
            imageObservations.append(item.observe(\.image) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            })
            imageObservations.append(item.observe(\.selectedImage) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            })
            if !Self.sameImage(item.image, images.unselected) { item.image = images.unselected }
            if !Self.sameImage(item.selectedImage, selectedImage) { item.selectedImage = selectedImage }
        }
    }

    private func observe(_ controller: UITabBarController) {
        guard controller !== observedTabBarController else { return }
        containerObservations.removeAll()
        observedTabBarController = controller
        containerObservations = [
            controller.observe(\.tabs) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            },
            controller.tabBar.observe(\.items) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            },
            controller.observe(\.selectedTab) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            }
        ]
    }

    /// UIKit 可以拷贝 UIImage；比较实际内容，避免相同图片反复赋值触发布局。
    private static func sameImage(_ current: UIImage?, _ expected: UIImage) -> Bool {
        guard let current, current.renderingMode == expected.renderingMode,
              current.size == expected.size, current.scale == expected.scale,
              current.imageOrientation == expected.imageOrientation else { return false }
        if current.isEqual(expected) { return true }
        if let cgImage = current.cgImage, cgImage === expected.cgImage { return true }
        guard let data = current.pngData() else { return false }
        return data == expected.pngData()
    }

    // MARK: - 每个槽位的两张图

    /// 同一个品牌的两张图：未选中（模板，吃系统未选中色）+ 选中（品牌原色）。
    private struct SlotImages {
        let unselected: UIImage
        let selected: UIImage
    }

    private func selectedImage(for slot: TabBarBrandSlot, images: SlotImages) -> UIImage {
        let section: AppModel.Section = switch slot {
        case .home: .home
        case .bangumi: .my
        case .moviepilot: .my
        }
        return selectedSection == section ? images.selected : images.unselected
    }

    /// 品牌资产缓存成 `static let`：`UIImage(named:)` 本身有缓存，但 `withRenderingMode`
    /// 每次都会产生新实例。`apply()` 会被调用多次（首帧 + 头像到达 + 每次界面更新），
    /// 没必要每次都重新建图。
    private enum Asset {
        static let bangumiTemplate = UIImage(named: "bangumi-logo")?
            .withRenderingMode(.alwaysTemplate)
        /// Bangumi 的单色线稿与渐变版是两份资产（同一 glyph）。
        static let bangumiColor = UIImage(named: "bangumi-logo-color")?
            .withRenderingMode(.alwaysOriginal)
        /// MoviePilot 的彩色渐变就在**同一份** SVG 里：`template-rendering-intent` 只影响默认
        /// 渲染模式，`.alwaysOriginal` 会按 SVG 原本的颜色画（实测紫色渐变完整保留）。
        static let moviepilotTemplate = UIImage(named: "moviepilot-logo")?
            .withRenderingMode(.alwaysTemplate)
        static let moviepilotColor = UIImage(named: "moviepilot-logo")?
            .withRenderingMode(.alwaysOriginal)
    }

    private func images(for slot: TabBarBrandSlot) -> SlotImages? {
        switch slot {
        case .bangumi:
            guard let template = Asset.bangumiTemplate,
                  let color = Asset.bangumiColor else { return nil }
            return SlotImages(unselected: template, selected: color)
        case .moviepilot:
            guard let template = Asset.moviepilotTemplate,
                  let color = Asset.moviepilotColor else { return nil }
            return SlotImages(unselected: template, selected: color)
        case .home:
            // 没头像：系统的 `house.fill` 本来就靠前景色亮暗区分两态，不接管。
            guard let avatar else { return nil }
            if grayAvatar == nil { grayAvatar = AppModel.grayscaleTabIcon(from: avatar) }
            guard let gray = grayAvatar else { return nil }
            return SlotImages(unselected: gray, selected: avatar)
        }
    }

    // MARK: - 找标签栏控制器

    private static func findTabBarController(from controller: UIViewController) -> UITabBarController? {
        // ① 祖先链：如果这个 representable 恰好落在 TabView 的子树里，这是最近的答案。
        if let tabBarController = controller.tabBarController { return tabBarController }
        // ② 兜底：它挂在 `TabView` 的 `.background` 上，与标签栏控制器是**兄弟**关系
        //    （共同的祖先是窗口的 hosting controller），所以从根往下广度优先找。
        var root: UIViewController = controller
        while let parent = root.parent { root = parent }
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let tabBarController = current as? UITabBarController { return tabBarController }
            queue.append(contentsOf: current.children)
            if let presented = current.presentedViewController { queue.append(presented) }
        }
        return nil
    }
}

#endif
