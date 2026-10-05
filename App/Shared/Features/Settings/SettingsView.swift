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
    /// 首页栏目：只用于「显示 N 栏」值预览，编辑在「首页栏目」子页。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw
    private var homeSections: [HomeSection] { HomeSectionPreference.decode(homeSectionsRaw) }

    var body: some View {
        Form {
            Section("服务") {
                hubRow(.jellyfin, icon: "server.rack", value: jellyfinValue)
                hubRow(.bangumi, icon: "tv", value: bangumiValue)
                hubRow(.moviepilot, icon: "arrow.down.circle", value: moviePilotValue)
            }
            .settingsRowBackground()

            Section("播放与界面") {
                hubRow(.playback, icon: "play.circle", value: PlaybackEngineRegistry.selected?.displayName)
                hubRow(.danmaku, icon: "text.bubble", value: danmakuValue)
                hubRow(.homeSections, icon: "square.grid.2x2", value: "显示 \(homeSections.count) 栏")
            }
            .settingsRowBackground()

            Section("网络与元数据") {
                hubRow(.tmdb, icon: "film.stack", value: app.tmdb.isConfigured ? "已启用" : "未启用")
                hubRow(.network, icon: "network", value: customUserAgent.isEmpty ? "默认 UA" : "自定义 UA")
            }
            .settingsRowBackground()

            Section {
                hubRow(.maintenance, icon: "wrench.and.screwdriver")
                hubRow(.about, icon: "info.circle", value: AppVersion.displayString)
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .formStyle(.grouped)
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

    // MARK: - 导航行

    /// 整行可点 + 右侧 chevron；值预览窄屏下中间截断（iOS 设置的行内值口径）。
    /// 用按钮而不是 NavigationLink：落地走 `pushPresented` 两段式，与路由页一致。
    private func hubRow(_ subpage: SettingsSubpage, icon: String, value: String? = nil) -> some View {
        Button {
            app.openSettingsSubpage(subpage)
        } label: {
            HStack(spacing: 10) {
                Label(subpage.title, systemImage: icon)
                Spacer(minLength: 8)
                if let value, !value.isEmpty {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组行底（iOS）

extension View {
    /// 清空 Form 分组的行底。**iOS 专用**：iOS 的 grouped Form 行底是系统不透明白
    /// （`scrollContentBackground(.hidden)` 只管列表底，管不到行底），会把垫在页面里的
    /// 氛围图挡死；macOS 的分组玻璃本来就近乎零填充、观感正确，直通不动。
    ///
    /// 注意必须挂在**每个 Section** 上：挂在 Form 上不生效（行底是逐行的 trait，
    /// Form 自己是容器，写在它外面的值传不到行）。材质 / glassEffect / 调透明度都试过，
    /// 都自带一层模式色纱，跟 `.home` 遮罩叠出来还是「死白」，所以直接全透：
    /// 分组结构交给 Section 标题与分隔线表达，行浮在氛围图上（同 macOS 观感）。
    func settingsRowBackground() -> some View {
        #if os(iOS)
        listRowBackground(Color.clear)
        #else
        self
        #endif
    }
}
