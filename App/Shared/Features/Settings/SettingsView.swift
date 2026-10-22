import AppDesignKit
import DanmakuKit
import JellyfinKit
import PlaybackKit
import SwiftUI

/// 设置页 = **hub 首屏**：一屏导航行，每行带当前值预览，具体设置在子页。
///
/// 子页清单见 `SettingsSubpage`；push 走 `Route.settingsSubpage`（path 驱动，
/// 而非 `navigationDestination(isPresented:)`）——hub 的子页还会再推自己的
/// 叶子页（Jellyfin 页推「管理服务器」、关于页推「开源许可证」），isPresented
/// 页面不在 path 上，祖先得靠 `coveredByPresented` 逐层登记才不漏底；path
/// 驱动由根级 opacity 与 `coveredPageHidden` 按深度自动隐藏整条链。
///
/// 原则不变：这里只放导航与状态——播放入口在首页工具栏与 macOS 文件菜单，
/// 工程说明不进设置页；说明文字跟着功能进各自子页。值预览是给用户不进子页
/// 就能看到的「现在什么状态」（iOS 系统设置的一级页口径）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(DanmakuModel.self) private var danmakuModel

    /// 集成开关只影响值预览与子页内容；hub 行常驻——关了也要有地方再打开。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true
    /// 自定义 User-Agent（空 = 系统默认）：只用于值预览，编辑在「网络」子页。
    @AppStorage(ClientIdentity.customUserAgentKey) private var customUserAgent = ""
    /// 首页栏目：只用于值预览，编辑在「首页栏目」子页。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw

    var body: some View {
        // **2026-10-22（B 方案：玻璃卡片流）**：设置页整体脱离 `Form`，改成
        // `ScrollView` + 玻璃卡片流——与 MoviePilot 下载页同一套承载。分段表仍在
        // `SettingsHub`（唯一事实源），每段 = 一张 `SettingsGlassCard`。
        SettingsGlassPage {
            ForEach(SettingsHub.groups) { group in
                SettingsGlassSection(group.title) {
                    ForEach(Array(group.subpages.enumerated()), id: \.element) { index, subpage in
                        if index > 0 { SettingsGlassDivider() }
                        hubRow(subpage, value: value(for: subpage))
                    }
                }
            }

            TMDbAttributionFooter()
        }
        .navigationTitle("设置")
        #if !os(macOS)
        // iPhone / iPad：Tab 根页不挂大标题——「设置」已写在底部 Tab 上，顶部再挂
        // 一遍只白占一截（与首页同一口径，见 HomeView 顶部注释）。子页不受影响：
        // 子页是 push 页，标题统一在 AppShell.settingsSubpageView 给定。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
    }

    /// 每行的值预览。集中在一处、按子页穷举分派——原先值是**逐个行手写**在各自的
    /// `Section` 里的（`hubRow(.jellyfin, icon: …, value: jellyfinValue)`），于是
    /// 「哪一页有值预览、预览什么」这件事散在四个 Section 的调用点上。
    /// 现在它是一处穷举 `switch`：新增子页时**编译器**会要求在这里表态
    /// （不加 case 就不通过），「忘了给新页配值预览」从静默遗漏变成编译错误。
    private func value(for subpage: SettingsSubpage) -> String? {
        switch subpage {
        case .jellyfin: jellyfinValue
        case .bangumi: bangumiValue
        case .moviepilot: moviePilotValue
        case .tmdb: app.tmdb.isConfigured ? "已启用" : "未启用"
        case .network: customUserAgent.isEmpty ? "默认 UA" : "自定义 UA"
        case .playback: PlaybackEngineRegistry.selected?.displayName
        case .danmaku: danmakuValue
        case .homeSections: homeSectionsValue
        // 维护 / 关于：没有「一眼可见的状态」，行尾只有箭头（对照产品同款口径）。
        case .maintenance: nil
        case .about: AppVersion.displayString
        }
    }

    // MARK: - 值预览

    private var jellyfinValue: String {
        app.server?.profile.serverName ?? "未连接"
    }

    /// 以 `isAuthenticated` 为准（登录的唯一门控信号），与子页口径一致：
    /// 资料没拉回来时显示「已登录」而不是误报「未登录」。
    private var bangumiValue: String {
        guard bangumiEnabled else { return "已关闭" }
        if let profile = bangumi.profile { return profile.name }
        return bangumi.isAuthenticated ? "已登录" : "未登录"
    }

    /// 三态取自 `integrationState`，与分区首页同一判据（见子页同名注释）。
    private var moviePilotValue: String {
        guard moviepilotEnabled else { return "已关闭" }
        return switch moviepilot.integrationState {
        case .unconfigured: "未配置"
        case .loggedOut: "未登录"
        case .ready: "已登录"
        }
    }

    private var danmakuValue: String {
        danmakuModel.danmaku.isAutoLoadingEnabled ? "自动加载" : "手动加载"
    }

    /// 首页栏目：全开时只说栏数；有关掉的显示「M/N 栏」——关掉的栏目在设置页
    /// 仍然列着（可随时再打开），值预览把这件事摆到一级页，免得用户以为丢了。
    private var homeSectionsValue: String {
        let layout = HomeSectionPreference.decode(homeSectionsRaw)
        return layout.hidden.isEmpty
            ? "显示 \(layout.order.count) 栏"
            : "显示 \(layout.visible.count)/\(layout.order.count) 栏"
    }

    // MARK: - 导航行

    /// 整行可点 + 右侧 chevron；值预览窄屏下中间截断（iOS 设置的行内值口径）。
    /// 用按钮而不是 NavigationLink：落地走 `pushPresented` 两段式，与路由页一致。
    ///
    /// 行身（图标列 / 单色 glyph / 分隔线对齐 / 行高）全部走 `SettingsNavRow`
    /// ——原先 `Label` 会让**图标吃系统强调色**（对照产品是白色单色，见
    /// `SettingsRowIcon`），且图标宽度会带动文字 leading 一起漂。
    private func hubRow(_ subpage: SettingsSubpage, value: String?) -> some View {
        SettingsNavRow(
            title: subpage.title,
            // 图标来源在 `SettingsSubpage.icon`（符号或品牌图）。
            icon: subpage.icon,
            value: value
        ) {
            app.openSettingsSubpage(subpage)
        }
    }
}

// MARK: - TMDB 署名

/// 设置页**最底部**的 TMDB 署名（官方要求的那一句 + 官方字标）。
///
/// 用户 2026-10-13 口径：「设置最底部加上给你的这张图这个」——给的是 TMDB 官方的
/// 署名图（字标 + `This product uses the TMDB API but is not endorsed or certified
/// by TMDB.`）。**为什么不直接放那张图**：那是 Rex 的**截图**，紫色背景是它自己的
/// 界面底色、被一起烤进了 JPEG；贴到我们这层氛围背景上会是一块突兀的方片。
/// 所以按它的**内容**重建：官方字标（用仓里既有的矢量资产 `tmdb-logo`，
/// 与详情页「在 TMDB 打开」同一份）+ 官方要求的**英文原文**。
///
/// 用**英文原文**而不是仓里已有的中文译句（`OpenSourceLicensesView` / TMDB 子页里那句）
/// 是因为 TMDB 的条款给的是这一句固定表述，署名以原文最稳妥；两处译句保留不动
/// （职责不同：那两处是条款说明，这里是品牌署名）。
///
/// 位置：**卡片之外**、`Form` 的最后一个 Section——署名是「页脚级别的法务信息」，
/// 不参与分组，所以不挂 `settingsCard()`，也不该长得像一行可点的设置项。
struct TMDbAttributionFooter: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("tmdb-logo")
                // **保持品牌配色**（`.original`）：这是 TMDB 的官方字标，
                // 与详情页「在 TMDB 打开」同一条口径——改色等于改品牌标识。
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 96)
                // 署名是装饰性文案，读屏念一遍商标名没有意义（文字里已经说明
                // 用了 TMDB API）；与行图标同一条无障碍口径。
                .accessibilityHidden(true)

            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - 已退役的旧卡底

// 2026-10-13 的 `settingsCard()`（iOS `listRowBackground(SettingsCardFill())` 半透明纯色
// 叠加）与 `settingsSectionSpacing()`（`listSectionSpacing`）随 B 方案一并退役：
// 设置页不再走 `Form`，卡底由 `SettingsGlassCard` 承担、段间距由
// `SettingsGlassPage` 的 VStack spacing 承担。
//
// 为什么退役而不是留着：逐行 `listRowBackground` 在 macOS 上**根本不被执行**
// （诊断页连不透明品红都不画），在 iOS 上逐行各画一块会出接缝——两条都实测过，
// 理由与实测数字写在 `SettingsGlassCard` 的文件头。
//
// 旧实现（`SettingsCardFill` + `cardFillDarkOpacity` / `cardFillLightOpacity`）的代码
// 与注释**已随本批一起删除**，只在 `CHANGELOG.md` 的 2026-10-13 条目里留了记录
// （那份记录解释了「当年为什么选纯色而不是 material」：亮色透出度 0.37 < 白 0.30 的
// 0.70）。要看历史请翻 CHANGELOG，不要在这里找那个原语——它已经不存在了。
