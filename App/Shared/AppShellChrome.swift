import AppDesignKit
import CoreModel
import SwiftUI

// MARK: - 顶栏导航（取代侧栏）
//
// 常规布局（macOS / iPad）原先靠 `NavigationSplitView` 侧栏承载三个分区入口、
// 媒体库列表和底部「设置」行。侧栏整列让给内容之后，导航改成顶栏两件：
//
//   1. `AppShellSectionGroup` —— 一组**纯图标**按钮（首页 / MoviePilot / Bangumi /
//      设置，顺序沿用原侧栏），共用一个液态玻璃圆角容器。
//   2. `AppShellLibraryButton` —— 媒体库单独一颗同款图标按钮，点开才是各库列表
//      （`AppShellLibraryPicker`）。它不并进上面那组：媒体库是「进哪个库」的选择，
//      和「在哪个分区」不是一回事，混进同一组会让人以为它们是同级页面。
//
// 版式对着 macOS 26 Safari 工具栏那组按钮做：纯图标、28pt 高、圆角容器（不是
// 整条胶囊）、组内按钮各自带 hover/选中底。顶栏空间本来就紧，图标化之后整组
// 只有原来文字版的三分之一宽，标题与搜索框不用再抢位置。

/// 顶栏导航条：分区图标组 + 媒体库按钮。
struct AppShellNavigationBar: View {
    var body: some View {
        HStack(spacing: 10) {
            AppShellSectionGroup()
            AppShellLibraryButton()
        }
    }
}

#if os(macOS)

/// macOS 窗口工具栏内容：分区图标组 + 媒体库按钮，同处一条系统共享胶囊。
///
/// **挂载在导航栈根内容上**（`appShellChrome()`，不是窗口级 `.toolbar`）：
/// push 进详情页后这两样随根页一起撤下，只留系统返回键——返回键独享一颗
/// 原生胶囊，不会和分区组画成一条。之前挂在窗口级 `.toolbar` 上时它们属于
/// 窗口、push 后照样在；而且 `ToolbarContent` 不随 `app.path` 变化重算，
/// `if path.isEmpty` 门控从未生效。
///
/// 分区组与媒体库按钮**有意共处一条胶囊**（用户确认过的外观）：媒体库的
/// 「在哪个库」状态靠强调色底区分，不拆独立胶囊。
struct AppShellNavigationToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            AppShellSectionGroup()
        }

        ToolbarItem(placement: .navigation) {
            AppShellLibraryButton()
        }
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
        let section: AppModel.Section
        let title: String
        let icon: String

        var id: AppModel.Section { section }
    }

    /// 顺序沿用侧栏：首页 → MoviePilot → Bangumi → 设置。
    static func makeSegments(bangumiEnabled: Bool, moviepilotEnabled: Bool) -> [Segment] {
        var segments: [Segment] = [Segment(section: .home, title: "首页", icon: "house.fill")]
        if moviepilotEnabled {
            segments.append(Segment(section: .moviepilot, title: "MoviePilot", icon: "film.stack"))
        }
        if bangumiEnabled {
            segments.append(Segment(section: .bangumi, title: "Bangumi", icon: "tv.fill"))
        }
        segments.append(Segment(section: .settings, title: "设置", icon: "gearshape"))
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
            app.selectedSection = segment.section
        } label: {
            Image(systemName: segment.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 24)
                .contentShape(.rect(cornerRadius: 6))
                .background(
                    segmentBackground(isSelected: isSelected, isHovering: isHovering),
                    in: .rect(cornerRadius: 6)
                )
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

    private func segmentBackground(isSelected: Bool, isHovering: Bool) -> AnyShapeStyle {
        // macOS 工具栏的 Liquid Glass 会把低 alpha 的内容填充当「背景」吃掉
        // （实测 accent 0.32 / primary 0.08 全部不可见），这两个档位按玻璃上
        // 可见的下限取，比 iPad 内容层（0.32 / 0.08）浓一档。
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.55)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.14)) }
        return AnyShapeStyle(.clear)
    }
}

// MARK: - 媒体库按钮

/// 「媒体库」按钮：与分区组同款的玻璃图标按钮，点开弹出各库列表。
/// 已经在某个库里时换成**该库的类型图标 + 强调色底**，一眼能看出身处哪个库，
/// 也就不用再往分区组里塞一个「媒体库」按钮去表示这个状态。
struct AppShellLibraryButton: View {
    @Environment(AppModel.self) private var app
    @State private var isPickerPresented = false
    @State private var isHovering = false

    private var currentLibrary: MediaLibrary? {
        guard case .library(let id) = app.selectedSection else { return nil }
        return app.libraries.first { $0.id == id }
    }

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            HStack(spacing: 2) {
                Image(systemName: currentLibrary.map { AppShellView.icon(for: $0.collectionType) } ?? "square.stack")
                    .font(.system(size: 13, weight: .semibold))
                // 与 Safari 的「历史记录」按钮同一处理：带小箭头表示点开是列表。
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(currentLibrary == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // 尺寸 / hover / 选中底两个平台一致：系统共享胶囊不给组内按钮画底，
            // 「在哪个库」的强调色状态必须落在内容层（iPad 上一直有；macOS
            // 之前写在 `#if !os(macOS)` 里，进了库也看不出来）。
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                background,
                in: .rect(cornerRadius: 6)
            )
            .motion(Motion.fast, value: currentLibrary?.id)
            .motion(Motion.fast, value: isHovering)
        }
        // macOS 也显式 `.plain`：默认工具栏按钮样式会自己再画一层 hover / 按下
        // 玻璃，叠在系统的共享胶囊上就是双份。
        .buttonStyle(.plain)
        #if !os(macOS)
        // iOS 的 principal 位没有系统胶囊，按钮自己出一颗；macOS 与分区组共处
        // 系统共享胶囊（见 `AppShellNavigationToolbarContent`），不再自画。
        .padding(2)
        .glassEffect(.regular, in: .rect(cornerRadius: 9, style: .continuous))
        #endif
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            AppShellLibraryPicker(isPresented: $isPickerPresented)
        }
        .help(currentLibrary.map { "媒体库：\($0.name)" } ?? "选择媒体库")
        .accessibilityLabel(currentLibrary.map { "媒体库，当前 \($0.name)" } ?? "选择媒体库")
    }

    private var background: AnyShapeStyle {
        // 与 `AppShellSectionGroup.segmentBackground` 同档：玻璃上低 alpha 填充
        // 会被 Liquid Glass 吃掉（见那边的注释）。
        if currentLibrary != nil { return AnyShapeStyle(Color.accentColor.opacity(0.55)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.14)) }
        return AnyShapeStyle(.clear)
    }
}

/// 媒体库选择面板：列出服务器上现有的库，当前库打勾；库还没加载出来时给出
/// 失败原因与重试——这段原本住在侧栏里，侧栏撤掉后必须跟着搬过来，否则
/// 「媒体库拉取失败」在常规布局下就彻底没有出口了。
struct AppShellLibraryPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    @State private var hovering: MediaLibrary.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("媒体库")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

            if app.libraries.isEmpty {
                emptyState
            } else {
                ForEach(app.libraries) { library in
                    row(library)
                }
            }
        }
        .padding(6)
        .frame(width: 236)
    }

    private func row(_ library: MediaLibrary) -> some View {
        let isCurrent = app.selectedSection == .library(library.id)
        return Button {
            app.selectedSection = .library(library.id)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AppShellView.icon(for: library.collectionType))
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(library.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                isCurrent || hovering == library.id ? Color.primary.opacity(0.08) : .clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? library.id : (hovering == library.id ? nil : hovering) }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = app.librariesError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(UIStrings.retry) {
                    Task { await app.reloadBrowserData() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else {
            Text("还没有媒体库")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - 挂载点

extension View {
    /// 把顶栏导航条挂到导航栈的根内容上（iOS 的导航栏由栈自己提供）。
    ///
    /// macOS：分区图标组 + 媒体库按钮挂在这里（`placement: .navigation`）——挂在
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
