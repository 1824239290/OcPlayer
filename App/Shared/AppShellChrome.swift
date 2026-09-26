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

/// macOS 工具栏内容：让每个入口直接成为系统工具栏按钮，和右侧的打开、刷新、搜索
/// 使用同一套原生 Liquid Glass 适配，而不是把多个按钮再包进一层自绘玻璃。
struct AppShellNavigationToolbarContent: ToolbarContent {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

    var body: some ToolbarContent {
        ForEach(AppShellSectionGroup.makeSegments(
            bangumiEnabled: bangumiEnabled,
            moviepilotEnabled: moviepilotEnabled
        )) { segment in
            ToolbarItem(placement: .navigation) {
                let isSelected = app.selectedSection == segment.section
                Button {
                    guard !isSelected else { return }
                    app.selectedSection = segment.section
                } label: {
                    Image(systemName: segment.icon)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .help(segment.title)
                .accessibilityLabel(segment.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
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
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.32)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.08)) }
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
            #if !os(macOS)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                background,
                in: .rect(cornerRadius: 6)
            )
            .motion(Motion.fast, value: currentLibrary?.id)
            .motion(Motion.fast, value: isHovering)
            #endif
        }
        #if !os(macOS)
        .buttonStyle(.plain)
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
        if currentLibrary != nil { return AnyShapeStyle(Color.accentColor.opacity(0.32)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.08)) }
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
    /// macOS 是空操作：那边挂在 `AppShellView` 根的**窗口工具栏**上，工具栏属于
    /// 窗口而不属于某个栈，push 进详情页后这组按钮照样在（换页不必先返回）。
    @ViewBuilder
    func appShellChrome() -> some View {
        #if os(macOS)
        self
        #else
        toolbar {
            ToolbarItem(placement: .principal) {
                AppShellNavigationBar()
            }
        }
        #endif
    }
}
