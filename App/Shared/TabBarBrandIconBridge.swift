#if os(iOS)

import AppDesignKit
import SwiftUI
import UIKit

/// iOS 标签栏里「品牌图标 / 首页头像」的选中态渲染：**选中 = 彩色原图，未选中 = 灰**。
///
/// 用户口径（2026-10-22）：Bangumi / MoviePilot 两个 Tab 的图标现在只有「亮一点 / 暗一点」
/// 的单色差，要改成和首页头像（以及 macOS 顶栏药丸）同一套语言 —— 选中时是 SVG 原本的
/// 品牌色，未选中时是灰的。
///
/// ## 为什么必须下到 UIKit（而不是继续用 SwiftUI 的 `Tab`）
///
/// SwiftUI 的 `Tab` 只接收**一张**图片，标签栏自己决定两态怎么画：
///
/// * `Tab("Bangumi", image:)` 走模板渲染 → 两态都是单色（选中 `primary`、未选中 `secondary`），
///   也就是现在的「选中白一点、未选中灰一点」；
/// * 给 label 里的 `Image` 套 `.renderingMode(.original)` 能保住颜色，但**两态都会是彩色**
///   （标签栏不会对 `alwaysOriginal` 图做未选中灰化）；
/// * 在 label 里套 `.grayscale` / `.saturation` / `.opacity` 或者 `if isSelected` 条件视图
///   **全部无效**：标签栏只取 label 里那张 `Image` 的底层位图，SwiftUI 的绘制修饰符在交给
///   标签栏之前就被丢掉了（实测：五格图标加与不加逐像素相同；条件视图则会画出一块黑色
///   圆角块，见 `AppShellView.compactTabs` 的实拍约束）。
///
/// 而 `UITabBarItem` 本来就是为这件事设计的：`image` 是未选中图、`selectedImage` 是选中图，
/// **两张都钉 `alwaysOriginal`** 时系统不染色 —— 于是「未选中模板灰 / 选中品牌彩色」可以
/// 直接表达成两张图。问题只是 SwiftUI 没有暴露它（`Tab` 的 init 没有 `selectedImage`；
/// UIKit 侧 `UITab.selectedImage` 到 iOS 26.1 才有，SwiftUI 27.1 SDK 里也没有对应入口）。
///
/// 所以这里只做一件事：找到 SwiftUI `TabView` 底下那个 `UITabBarController`，按标题把
/// 三个槽位的 `image` / `selectedImage` 换成我们准备好的两张图。标签栏本身还是系统那一个
/// ——几何、玻璃底、搜索栏展开、iPad 尺寸类适配、无障碍全部不动，不需要自绘标签栏。
///
/// ## 实测（iPhone 17 Pro / iPad Pro 13″ / iOS 26.3 模拟器，最小探针 App，与 App 同构）
///
/// * **组合成立**：未选中用模板图（系统按未选中色染色，深色 ≈ `#F4F4F4`、浅色 ≈ `#000`，
///   与齿轮 / 放大镜完全同色）、选中用原色图（两态都不被染色）。彩色图用矢量资产直接
///   `.alwaysOriginal` 即可，**不用**按点尺寸烤位图。
/// * **两态同尺寸**：`bangumi-logo`（模板）与 `bangumi-logo-color` 是同一 viewBox 的同一
///   glyph，`.alwaysOriginal` 的矢量图按同一自然尺寸画；实测选中/未选中图标外接框逐像素
///   同宽（68px @3x），切换不跳。
/// * **注入的图会被 SwiftUI 重置**（实机 + 模拟器都复现过）：头像到达会换掉
///   `compactTabs` 的「有无头像」两条分支，标签栏项被重建 / 被重置回 label 那张彩色图，
///   而 `updateUIViewController` 是在**之前**调的 —— 结果首页那一格又变回彩色。
///   所以两处各排一串**有界**补拍（0.1 / 0.3 / 0.8 / 1.6 / 3.0 s），全部结束即停；
///   换选中 / 改无关状态都不会触发重置，注入一直有效。
/// * **label 仍放模板图**（不是彩色图）：万一某次注入没赶上或系统重置了 item，回落的是
///   现在的单色图标，而不是「两态都彩色」的错态。
///
/// ## 与 macOS 药丸的分工
///
/// macOS 没有标签栏（分区入口是窗口工具栏里的玻璃药丸），那边是纯 SwiftUI、按状态切
/// `.renderingMode`（见 `SectionBrandIcon`）；这里只服务 iOS 的 `TabView`。
struct TabBarBrandIconBridge: UIViewControllerRepresentable {
    /// 当前账号头像（iOS 上已经烤成标签栏版本：28pt 圆 + `alwaysOriginal`）。
    /// `nil` = 没头像，首页那格保持系统的 `house.fill`，这里不接管。
    let avatar: PlatformImage?

    func makeUIViewController(context: Context) -> TabBarBrandIconController {
        let controller = TabBarBrandIconController()
        controller.avatar = avatar
        return controller
    }

    func updateUIViewController(_ controller: TabBarBrandIconController, context: Context) {
        controller.avatar = avatar
        // ⚠️ 这一句跑在 SwiftUI **提交重建之前**：标签栏项被重建时（头像到达会换掉
        // `compactTabs` 的「有无头像」分支），此刻注入的图会被随后那一轮重建冲掉。
        // 所以再排两拍：下一拍（重建已提交）+ 稍后一拍（图布局稳定）。
        controller.apply()
        DispatchQueue.main.async { controller.apply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { controller.apply() }
    }
}

/// 要接管的标签栏槽位。**按标题匹配** —— 整条路唯一脆的地方，所以抽成纯函数用单例钉住。
///
/// 为什么不用下标 / 标识：SwiftUI 的 `Tab` 没有给 `UITabBarItem` 打标识的 API，能稳定拿到
/// 的只有标题；而这三个标题在 `AppShellView.compactTabs` 里是写死的裸字符串（不是本地化
/// 资源），不会随语言变。认不出来的标题（设置 / 搜索 / 以后新增的 Tab）一律不接管。
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
    /// 当前账号头像（已经烤成标签栏版本）。换图时才需要重烤灰色那张。
    var avatar: UIImage? {
        didSet {
            if avatar !== oldValue { grayAvatar = nil }
        }
    }

    private var grayAvatar: UIImage?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
        // 首帧之后标签栏项还会被重建若干次（头像到达 → 换掉「有无头像」分支；
        // 冷启动时图片缓存预热也会改一次），而重建**不保证**有回调。所以在一个
        // 有界的窗口里补几拍：0.1 / 0.3 / 0.8 / 1.6 / 3.0 s。全部结束即不再排任务
        // （之后的变化由 `updateUIViewController` 驱动），不是常驻轮询。
        for delay in [0.1, 0.3, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.apply()
            }
        }
    }

    /// 把三个槽位换成「未选中图 / 选中图」。
    ///
    /// **无条件重设**。这里试过两种「没变就不写」的判据，都不成立：
    ///
    /// * ❌ **比较实例**：`UITabBarItem` 的 setter 会**拷贝**图片，写进去的对象与读出来
    ///   永远不是同一实例 —— 每次调用都判成「没生效」（日志里 `applied=0`，图其实换好了）。
    /// * ❌ **关联对象当记号**：SwiftUI 换头像时会**复用同一个** `UITabBarItem`、把 `image`
    ///   重置回 label 那张彩色图，对象没变、记号还在 —— 于是判成「已接管」，首页那一格
    ///   又变回彩色（浅色外观实拍抓到的）。
    ///
    /// 代价可接受：`apply()` 只在标签栏相关的更新时被调（首帧 + 有界补拍 + SwiftUI 更新），
    /// 不是每帧；三次赋值对系统标签栏来说是噪声级。
    func apply() {
        guard let tabBarController = Self.findTabBarController(from: self) else { return }
        for item in tabBarController.tabBar.items ?? [] {
            guard let slot = TabBarBrandSlot.slot(forTitle: item.title ?? ""),
                  let images = images(for: slot)
            else { continue }
            item.image = images.unselected
            item.selectedImage = images.selected
        }
    }

    // MARK: - 每个槽位的两张图

    /// 同一个品牌的两张图：未选中（模板，吃系统未选中色）+ 选中（品牌原色）。
    private struct SlotImages {
        let unselected: UIImage
        let selected: UIImage
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