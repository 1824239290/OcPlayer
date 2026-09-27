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

/// 分区切换组：一个玻璃圆角容器装若干纯图标按钮，当前分区带强调色底。
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
        /// 图标来源：SF Symbol 或品牌矢量图（Assets.xcassets imageset）。
        enum Icon {
            case symbol(String)
            /// `side`：品牌图渲染边长（pt）。各 SVG 在 viewBox 里的留白不同，
            /// 统一边长会显得一大一小，按图逐个标定。
            case brand(String, side: CGFloat)
        }

        let section: AppModel.Section
        let title: String
        let icon: Icon

        var id: AppModel.Section { section }
    }

    /// 顺序沿用侧栏：首页 → MoviePilot → Bangumi → 设置。
    static func makeSegments(bangumiEnabled: Bool, moviepilotEnabled: Bool) -> [Segment] {
        var segments: [Segment] = [Segment(section: .home, title: "首页", icon: .symbol("house.fill"))]
        if moviepilotEnabled {
            segments.append(Segment(section: .moviepilot, title: "MoviePilot", icon: .brand("moviepilot-logo", side: 18)))
        }
        if bangumiEnabled {
            segments.append(Segment(section: .bangumi, title: "Bangumi", icon: .brand("bangumi-logo", side: 20)))
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
            segmentIcon(segment.icon)
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
    /// 13pt Symbol 的视觉体量。两个 logo 均为模板渲染（见 imageset），
    /// 与 SF Symbol 一样跟随 primary/secondary 前景色。
    @ViewBuilder
    private func segmentIcon(_ icon: Segment.Icon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
        case .brand(let name, let side):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
        }
    }

    private func segmentBackground(isSelected: Bool, isHovering: Bool) -> AnyShapeStyle {
        // 选中态只靠前景色亮暗区分（选中 .primary / 未选中 .secondary），不画
        // 背景底——用户确认过不要蓝色的选中底。hover 保留浅色底。
        // macOS 工具栏的 Liquid Glass 会把低 alpha 的内容填充当「背景」吃掉
        // （实测 primary 0.08 不可见），hover 档按玻璃上可见的下限取。
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.14)) }
        return AnyShapeStyle(.clear)
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
