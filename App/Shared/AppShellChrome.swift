import AppDesignKit
import SwiftUI

// MARK: - 顶栏导航（取代侧栏）
//
// 常规布局（macOS / iPad）原先靠 `NavigationSplitView` 侧栏承载三个分区入口、
// 媒体库列表和底部「设置」行。侧栏整列让给内容之后，导航收进顶栏一组
// **纯图标**按钮（首页 / MoviePilot / Bangumi / 设置，顺序沿用原侧栏），
// 共用一个液态玻璃圆角容器。媒体库入口在首页「媒体库」栏（可关），这里
// 不再放独立的「媒体库」按钮。
//
// 版式对着 macOS 26 Safari 工具栏那组按钮做：纯图标、28pt 高、圆角容器（不是
// 整条胶囊）、组内按钮各自带 hover/选中底。顶栏空间本来就紧，图标化之后整组
// 只有原来文字版的三分之一宽，标题与搜索框不用再抢位置。

/// 顶栏导航条：分区图标组。
///
/// macOS：整组处**一条自绘玻璃胶囊**内（工具栏项退出系统共享胶囊后系统不再
/// 给底，见 `AppShellNavigationToolbarContent`）。胶囊内边距 / 图标节距 /
/// 选中底尺寸全部自绘控制——系统共享胶囊的内边距偏大且不可调。
struct AppShellNavigationBar: View {
    var body: some View {
        #if os(macOS)
        // 内容高 24pt + 上下各 6 → 胶囊 36pt。左右各留 8：首个图标离胶囊边缘
        // 太近会显得挤（视觉呼吸位），尾部箭头同理。
        AppShellSectionGroup()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
        #else
        AppShellSectionGroup()
        #endif
    }
}

#if os(macOS)

/// macOS 窗口工具栏内容：分区图标组 + 媒体库按钮一条胶囊（`AppShellNavigationBar`）。
///
/// **挂载在导航栈根内容上**（`appShellChrome()`，不是窗口级 `.toolbar`）：
/// push 进详情页后随根页一起撤下，只留系统返回键——返回键独享一颗原生胶囊，
/// 不会和分区组画成一条。之前挂在窗口级 `.toolbar` 上时它们属于窗口、push 后
/// 照样在；而且 `ToolbarContent` 不随 `app.path` 变化重算，`if path.isEmpty`
/// 门控从未生效。
///
/// 整条是一个工具栏项 + `.sharedBackgroundVisibility(.hidden)`：系统不再给
/// 共享胶囊（内边距偏大、且会把项间间距算进去），胶囊由内容层自绘，几何可
/// 精确对齐设计稿。
struct AppShellNavigationToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            AppShellNavigationBar()
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

#endif

// MARK: - 分区图标组

/// 分区切换组：一个玻璃圆角容器装若干纯图标按钮，当前分区**只靠图标自己的表现**
/// 区分：
/// * SF Symbol / 未选中的品牌图：前景色亮暗（选中 `.primary` / 未选中 `.secondary`）；
/// * 有头像时首页那一格：饱和度（选中原色 / 未选中灰化，见 `SectionAvatarIcon`）；
/// * 选中的品牌图（Bangumi / MoviePilot）：品牌原色（见 `SectionBrandIcon`）。
///
/// 三种信号不打架：它们各自只出现在「自己那一格是当前页」时才最亮/最有色，其余格
/// 一律退回中性灰。用户口径（2026-10-22）：品牌 logo 也要像首页头像那样，
/// **选中=彩色原图、未选中=灰**（iOS 标签栏同步改成同一套，见 `TabBarBrandIconBridge`）。
///
/// 容器玻璃只上**一层**（挂在整组上），组内按钮用内容层的半透明填充表示
/// hover / 选中：给玻璃上 tint 会顺着 `GlassEffectContainer` 的取样区域晕开，
/// 实测能把整条工具栏染成粉红色；半透明填充落在内容层，清晰、不晕、深浅色
/// 模式下都稳。
struct AppShellSectionGroup: View {
    @Environment(AppModel.self) private var app
    /// 两个集成的启用开关：关掉后对应按钮消失（与侧栏时代一致）。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

    @State private var hovering: AppModel.Section?

    /// 组里的一颗按钮。`id` 取 section，方便 ForEach 稳定复用。
    struct Segment: Identifiable {
        /// 图标来源：SF Symbol、品牌矢量图（Assets.xcassets imageset），或当前账号头像。
        enum Icon {
            case symbol(String)
            /// 品牌图：未选中用 `name`（模板渲染，吃前景色）；选中用 `colorName` 的
            /// **品牌原色**（`.renderingMode(.original)`）。两者是同一个官方 glyph；
            /// Bangumi 有单独的渐变版资产，MoviePilot 的彩色直接存在同一个 SVG 里
            /// （`colorName == name`，只是渲染模式不同）。
            /// `side`：品牌图渲染边长（pt）。各 SVG 在 viewBox 里的留白不同，
            /// 统一边长会显得一大一小，按图逐个标定。
            case brand(name: String, colorName: String, side: CGFloat)
            /// 首页那一格：当前账号的头像。没设头像时回落 `house.fill`
            /// （回落发生在 `segmentIcon` 里，不在段定义里——段是静态的）。
            case avatar
        }

        let section: AppModel.Section
        let title: String
        let icon: Icon

        var id: AppModel.Section { section }
    }

    /// 顺序沿用侧栏：首页 → MoviePilot → Bangumi → 设置。
    static func makeSegments(bangumiEnabled: Bool, moviepilotEnabled: Bool) -> [Segment] {
        var segments: [Segment] = [Segment(section: .home, title: "首页", icon: .avatar)]
        if moviepilotEnabled {
            segments.append(Segment(
                section: .moviepilot, title: "MoviePilot",
                icon: .brand(name: "moviepilot-logo", colorName: "moviepilot-logo", side: 18)
            ))
        }
        if bangumiEnabled {
            segments.append(Segment(
                section: .bangumi, title: "Bangumi",
                icon: .brand(name: "bangumi-logo", colorName: "bangumi-logo-color", side: 20)
            ))
        }
        segments.append(Segment(section: .settings, title: "设置", icon: .symbol("gearshape")))
        return segments
    }

    private var segments: [Segment] {
        Self.makeSegments(bangumiEnabled: bangumiEnabled, moviepilotEnabled: moviepilotEnabled)
    }

    var body: some View {
        let content = HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }

        #if os(macOS)
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("页面切换")
        #else
        content
            .padding(2)
            .glassEffect(.regular, in: .rect(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("页面切换")
        #endif
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = app.selectedSection == segment.section
        let isHovering = hovering == segment.section
        return Button {
            guard !isSelected else { return }
            // 常规布局走两段式（当前页淡出后再换分区），compact 由 AppModel 直切。
            app.switchSection(segment.section)
        } label: {
            segmentIcon(segment.icon, isSelected: isSelected)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 24)
                .contentShape(.rect(cornerRadius: 6))
                // 选中/hover 底内缩成 27×21 的小圆角块（槽位 28×24 各收
                // 0.5 / 1.5）——撑满槽位会让胶囊显得臃肿，内缩后图标与底
                // 的视觉间距才均匀。
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(segmentBackground(isSelected: isSelected, isHovering: isHovering))
                        .padding(.horizontal, 0.5)
                        .padding(.vertical, 1.5)
                }
                // 选中/hover 切换走短淡变，不做位移——组本身是静态几何。
                .motion(Motion.fast, value: isSelected)
                .motion(Motion.fast, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? segment.section : (hovering == segment.section ? nil : hovering) }
        .help(segment.title)
        .accessibilityLabel(segment.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// SF Symbol 走字体渲染；品牌图是矢量 imageset，按标定边长缩放对齐
    /// 13pt Symbol 的视觉体量。品牌图**未选中**走模板渲染（跟随 secondary 前景色），
    /// **选中**换成品牌原色（见 `SectionBrandIcon`）。
    ///
    /// 头像那一格是**位图**，既不吃 `foregroundStyle` 也不吃模板渲染，所以它的选中态
    /// 走另一条通道（饱和度），见 `SectionAvatarIcon`。
    @ViewBuilder
    private func segmentIcon(_ icon: Segment.Icon, isSelected: Bool) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
        case .brand(let name, let colorName, let side):
            SectionBrandIcon(name: name, colorName: colorName,
                             isSelected: isSelected, side: side)
        case .avatar:
            if let avatar = app.userAvatarImage {
                SectionAvatarIcon(image: avatar, isSelected: isSelected)
            } else {
                // 没有头像（服务端上头像是可选的，多数账号没设）——与改动前逐像素同款。
                Image(systemName: "house.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func segmentBackground(isSelected: Bool, isHovering: Bool) -> AnyShapeStyle {
        // 选中态不画强调色底（用户确认过不要蓝色的选中底）：glyph 靠前景色亮暗，
        // 品牌图 / 头像靠**自己的颜色信号**（见 `SectionBrandIcon` / `SectionAvatarIcon`）。
        // hover 保留浅色底。
        // macOS 工具栏的 Liquid Glass 会把低 alpha 的内容填充当「背景」吃掉
        // （实测 primary 0.08 不可见），hover 档按玻璃上可见的下限取。
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.14)) }
        return AnyShapeStyle(.clear)
    }
}

// MARK: - 头像格

/// 药丸里「首页」那一格的图标：当前账号的头像。选中 = 原色，未选中 = 灰化。
///
/// ## 为什么选中信号走**饱和度**而不是「亮暗」
///
/// 药丸现有的选中信号只有一条：前景色亮暗（选中 `.primary` / 未选中 `.secondary`）。
/// 头像接不进来 —— 位图不吃 `foregroundStyle`。按同构思路试过「未选中压暗 /
/// 降不透明」，**实测不成立**：
///
/// * 头像的亮度由**图片内容**决定，不由 App 决定。本机真实头像平均明度
///   **209/255**（偏亮），压在浅色玻璃上 `opacity(0.55)` 只剩 **Δ20/255**；
///   而相邻 glyph 的 primary ↔ secondary 是 **Δ120/255**（深色 96）—— 差 6 倍，
///   浅色模式下基本看不出来。
/// * 深色模式下方向还反了：变淡 = 往深底里沉 = 更像「选中」。
///
/// 灰化换的是**饱和度**通道：同一张头像平均饱和度 **57/255 → 0**（整条），
/// 与图片内容无关，深浅两种外观下都读得出来。代价是药丸多了一条只有这一格才有的
/// 信号通道 —— 这是刻意的取舍（另一条路是给所有 segment 补一个中性选中底，但那会
/// 和 hover 底撞车：悬停在非当前页上会和「当前页」长得一模一样）。
///
/// ## 与 hover 不冲突
///
/// hover 底只在鼠标悬停时出现（`primary@0.14`），于是四种组合都能区分：
/// 彩色无底 = 当前页；彩色有底 = 当前页且鼠标在这；灰色有底 = 鼠标在这但不是当前页；
/// 灰色无底 = 都不是。
struct SectionAvatarIcon: View {
    let image: PlatformImage
    /// 选中保留原色；未选中灰化。
    let isSelected: Bool
    /// 渲染边长（pt）。取 18 是量出来的：13pt（SF Symbol 那一档）实拍只剩一团粉、
    /// 认不出人，16pt 勉强，**18pt 起才看得出脸** —— 正好落在品牌 logo 已有的
    /// 18 / 20pt 档里，槽位（28×24）与胶囊高度（36pt）都不用动。
    var side: CGFloat = 18

    var body: some View {
        Image(platform: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(.circle)
            // 用 `.grayscale` 而不是 `.saturation(0)`：观感等价（都是把饱和度整条抽掉），
            // 但 **`.saturation()` 在 `ImageRenderer` 里不生效**（实测：纯色矩形与位图
            // 加与不加逐值相同，0.897 vs 0.897），而 `.grayscale()` 生效（0.762 → 0.000）。
            // 这一格唯一的选中信号就是它，必须能被渲染用例钉住。
            .grayscale(isSelected ? 0 : 1)
    }
}

// MARK: - 品牌图标

/// 药丸里的品牌图标（Bangumi / MoviePilot）：**选中 = 品牌原色，未选中 = 单色模板**。
///
/// ## 为什么资产层不动、只在这一层切渲染模式
///
/// 两个 imageset 都带 `template-rendering-intent`（Bangumi 另有一份渐变版
/// `bangumi-logo-color`），因为设置页行图标、详情页外链、药丸未选中态这些地方
/// 都要求单色。把 `template-rendering-intent` 从 imageset 里删掉会**同时**改掉那些
/// 地方；所以「彩色」只发生在**当前分区是它**时，由 `.renderingMode(.original)`
/// 在这一层按状态切换。
///
/// `.original` 能覆盖 imageset 的模板意图（实测：`Image("moviepilot-logo")`
/// 加 `.original` 后渲染成 SVG 里原本的紫色渐变，而不是一坨前景色）——MoviePilot
/// 的彩色本来就在同一个 SVG 里，所以 `colorName == name`；Bangumi 的单色线稿
/// 与渐变版共用同一 glyph，`colorName` 换成 `bangumi-logo-color`。
///
/// ## 与未选中态的衔接
///
/// 未选中仍走模板渲染 + 父层的 `.secondary`（与 SF Symbol 一致），所以**没选中时
/// 和改动前逐像素同款**；只有选中那一格从「白/黑单色」变成品牌色。两张图的几何
/// 完全一致（同一 viewBox / 同一 `side`），切换不会跳尺寸。
struct SectionBrandIcon: View {
    /// 未选中用的资产：单色模板（吃 `foregroundStyle`）。
    let name: String
    /// 选中用的资产：品牌原色。与 `name` 指向同一份资产时也成立（只是渲染模式不同）。
    let colorName: String
    let isSelected: Bool
    /// 渲染边长（pt）。各 SVG 在 viewBox 里的留白不同，按图逐个标定（18 / 20）。
    let side: CGFloat

    var body: some View {
        Image(isSelected ? colorName : name)
            // **必须紧跟 `Image`**：`.renderingMode` 是 `Image` 自己的方法，放到
            // `.resizable()` 之后类型已擦成 `some View`（编译不过）。
            .renderingMode(isSelected ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
    }
}

// MARK: - 挂载点

extension View {
    /// 把顶栏导航条挂到导航栈的根内容上（iOS 的导航栏由栈自己提供）。
    ///
    /// macOS：分区图标组挂在这里（`placement: .navigation`）——挂在
    /// **栈根内容**上，push 进详情页后随根页一起撤下，返回键独享一颗系统胶囊；
    /// 之前挂在窗口级 `.toolbar` 上时它们属于窗口、push 后照样在，还因为
    /// `ToolbarContent` 不随 `app.path` 变化重算，`if path.isEmpty` 门控从未生效。
    @ViewBuilder
    func appShellChrome() -> some View {
        #if os(macOS)
        toolbar {
            AppShellNavigationToolbarContent()
        }
        #else
        toolbar {
            ToolbarItem(placement: .principal) {
                AppShellNavigationBar()
            }
        }
        #endif
    }
}
