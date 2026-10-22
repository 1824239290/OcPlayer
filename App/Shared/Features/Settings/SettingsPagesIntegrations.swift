import AppDesignKit
import JellyfinKit
import SwiftUI

// MARK: - Jellyfin

/// 设置 → Jellyfin：当前服务器信息、启动默认选择与登录出口。
///
/// 列表的切换 / 删除仍在「管理服务器」子页（`ServersView`）——它是**叶子页**，
/// 不再下推别的页面，所以保留 `navigationDestination(isPresented:)` +
/// `coveredByPresented` 的呈现式写法（hub 的直接子页才走 path 路由）。
struct JellyfinSettingsView: View {
    @Environment(AppModel.self) private var app

    /// 管理服务器子页的落地开关。
    @State private var showServers = false
    /// 启动默认服务器的本地镜像。`ServerStore` 不是 `@Observable`，
    /// Picker 需要这份 @State 驱动选中态刷新；持久化仍以 store 为准。
    @State private var selectedDefaultServerID: String?
    @State private var confirmSignOut = false

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection("当前服务器") {
                KeyValueRow(label: "名称", value: app.server?.profile.serverName ?? "—")
                SettingsGlassDivider()
                KeyValueRow(
                    label: "地址",
                    value: (app.serverEndpointURL ?? app.server?.profile.baseURL)?.absoluteString ?? "—"
                )
                if let profile = app.server?.profile, !profile.addresses.isEmpty {
                    serverAddressNote(profile)
                }
            }

            if !app.store.profiles.isEmpty {
                SettingsGlassSection("启动") {
                    SettingsPickerRow("启动时默认服务器", selection: defaultServerBinding) {
                        Text("上次使用的服务器").tag(String?.none)
                        ForEach(app.store.profiles) { profile in
                            Text(profile.serverName + " · " + profile.kind.displayName)
                                .tag(String?.some(profile.id))
                        }
                    }
                    SettingsNote("打开 App 时优先连接这台。")
                }
            }

            SettingsGlassSection {
                // 换服务器不等于退出登录：`ServerStore` 是按 profile 存的，
                // 回登录流程连另一台就行，旧档案还在（登录页上「先不登录」可以退回来）。
                SettingsActionRow("管理服务器…", systemImage: "list.bullet") {
                    app.pushPresented { showServers = true }
                }
                SettingsGlassDivider()
                SettingsActionRow(
                    app.server == nil ? "连接服务器…" : "连接其它服务器…",
                    systemImage: "arrow.left.arrow.right"
                ) {
                    app.reconnectFlow()
                }
                SettingsGlassDivider()
                SettingsActionRow(
                    "退出 Jellyfin",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive
                ) {
                    confirmSignOut = true
                }
            }
        }
        .onAppear {
            selectedDefaultServerID = app.store.defaultServerID
            // 自动化深链（Debug-only）：`OCPLAYER_START_ROUTE=settings.jellyfin.servers`
            // 的标记由**宿主页**（本页）消费并展开。走 pushPresented 与手动点击完全
            // 同一条路，不另开呈现路径；消费即清（一次性）。
            if app.pendingPresentedLeaf == .servers {
                app.pendingPresentedLeaf = nil
                app.pushPresented { showServers = true }
            }
        }
        .navigationDestination(isPresented: $showServers) {
            ServersView()
                .appShellBackChrome(title: "管理服务器", presented: $showServers)
        }
        // 呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖：落地期间
        // 本页整页隐去，别透过半透的管理服务器页漏出（见 coveredByPresented）。
        .coveredByPresented($showServers)
        .confirmationDialog(
            "退出 Jellyfin？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { app.signOut() }
        } message: {
            Text("会停止播放并回到登录页；服务器地址档案保留，随时可以重新登录。")
        }
    }

    /// 启动默认服务器的双向绑定：读本地镜像（onAppear 从 store 同步），
    /// 写回时同时更新镜像与 `ServerStore`。
    private var defaultServerBinding: Binding<String?> {
        Binding(
            get: { selectedDefaultServerID },
            set: { newValue in
                selectedDefaultServerID = newValue
                app.store.defaultServerID = newValue
            }
        )
    }

    /// 多地址服务器的说明。只有一个入口时没什么可说，有备选地址才提
    /// 「自动择优 / 已固定」，并指出这些都能在「管理服务器」里改。
    @ViewBuilder
    private func serverAddressNote(_ profile: ServerProfile) -> some View {
        let active = (app.serverEndpointURL ?? profile.baseURL).absoluteString
        if let pinned = profile.pinnedURL {
            SettingsNote("已固定使用 \(pinned.absoluteString)，不会自动切换。")
        } else {
            SettingsNote("共 \(profile.allAddresses.count) 个地址：自动选择最快的（现在用的是 \(active)）；可在「管理服务器」里添加、删除或固定地址。")
        }
    }
}

// MARK: - Bangumi

/// 设置 → Bangumi：集成开关、账号与登录出口。
struct BangumiSettingsView: View {
    @Environment(BangumiCoordinator.self) private var bangumi

    /// 关闭后顶栏入口、详情页区块与后台同步一并隐藏/停止，凭据与关联数据保留。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @State private var confirmSignOut = false

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection {
                Toggle("启用 Bangumi", isOn: $bangumiEnabled)
                .neutralSwitch()
                if bangumiEnabled {
                    SettingsGlassDivider()
                    KeyValueRow(label: "账号", value: bangumiAccountText)
                    if bangumi.isAuthenticated {
                        SettingsGlassDivider()
                        // 退出登录原先只有 Bangumi 分区「我的」页顶栏一个出口：要退得先
                        // 切到那个分区、再进个人页，设置页里找不到——与 Jellyfin /
                        // MoviePilot 的出口位置对齐，这里补一个。
                        SettingsActionRow(
                            "退出 Bangumi",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            confirmSignOut = true
                        }
                    } else {
                        // 未登录时它就是「账号」行的注解（登录入口在哪儿），不是整段的说明。
                        SettingsNote("登录入口在顶栏的 Bangumi 分区。")
                    }
                } else {
                    SettingsNote("关闭后顶栏与详情页的 Bangumi 入口会隐藏；登录状态与条目关联保留。")
                }
            }
        }
        .confirmationDialog(
            "退出 Bangumi？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await bangumi.signOut() }
            }
        } message: {
            Text("本机的授权登录会清除；顶栏入口仍在，可随时重新授权。")
        }
    }

    /// 账号行：以 `isAuthenticated` 为准（它是登录的唯一门控信号）。
    /// 资料还没拉回来时 profile 为 nil，直接读它会显示成「未登录」——而旁边
    /// 就摆着「退出 Bangumi」，两行互相打架。
    private var bangumiAccountText: String {
        if let profile = bangumi.profile { return profile.name }
        return bangumi.isAuthenticated ? "已登录" : "未登录"
    }
}

// MARK: - MoviePilot

/// 设置 → MoviePilot：集成开关、服务器配置与登录出口。
struct MoviePilotSettingsView: View {
    @Environment(MoviePilotCoordinator.self) private var moviepilot

    /// 关闭后顶栏入口、详情页区块与后台同步一并隐藏/停止，服务器配置保留。
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true
    @State private var isEditingMoviePilot = false
    @State private var confirmSignOut = false

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection {
                Toggle("启用 MoviePilot", isOn: $moviepilotEnabled)
                .neutralSwitch()
                if moviepilotEnabled {
                    SettingsGlassDivider()
                    KeyValueRow(label: "地址", value: moviepilot.store.serverURLString ?? "—")
                    SettingsGlassDivider()
                    KeyValueRow(label: "用户", value: moviepilot.profile?.name
                        ?? (moviepilot.store.username.isEmpty ? "—" : moviepilot.store.username))
                    SettingsGlassDivider()
                    KeyValueRow(label: "状态", value: moviePilotStatusText)
                    SettingsGlassDivider()
                    SettingsActionRow(moviePilotActionButtonTitle) {
                        isEditingMoviePilot = true
                    }
                    SettingsGlassDivider()
                    // 默认关：密码不落盘。打开后存进凭据文件（已排除备份），
                    // 换来 JWT 8 天过期后的静默重登。
                    Toggle("记住密码（令牌过期后免重输）", isOn: Binding(
                        get: { moviepilot.rememberPassword },
                        set: { moviepilot.rememberPassword = $0 }))
                    .neutralSwitch()
                    SettingsNote("MoviePilot 的登录令牌 8 天过期且无法刷新。默认不保存密码："
                        + "到期后需要重新输入一次。打开此项会把密码存到本机凭据文件"
                        + "（已排除 iCloud / Time Machine 备份）。")
                    if moviepilot.isAuthenticated {
                        SettingsGlassDivider()
                        SettingsActionRow(
                            "退出 MoviePilot",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            confirmSignOut = true
                        }
                    }
                } else {
                    SettingsNote("关闭后顶栏与详情页的 MoviePilot 入口会隐藏；服务器配置保留。")
                }
            }
        }
        .sheet(isPresented: $isEditingMoviePilot) {
            MoviePilotServerSheet(
                initialURL: moviepilot.store.serverURLString ?? "",
                initialUsername: moviepilot.store.username
            )
        }
        .task {
            // 停用的集成不做任何启动期网络活动（profile 校验也跳过）。
            if moviepilotEnabled {
                moviepilot.refreshProfileIfNeeded()
            }
        }
        .confirmationDialog(
            "退出 MoviePilot？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await moviepilot.signOut() }
            }
        } message: {
            Text("登录令牌与账号资料会清除；服务器地址保留，重新登录即可恢复。")
        }
    }

    /// 状态行纯展示（点击不弹窗），操作按钮独立放置——与弹幕网关区块同规矩。
    /// 三态取自 `integrationState`，与分区首页同一判据（此前这里用 `isConfigured`
    /// 拼「凭据不全」，与首页的「未配置」打架，且默认不保存密码时就会命中）。
    private var moviePilotStatusText: String {
        switch moviepilot.integrationState {
        case .unconfigured: "未配置"
        case .loggedOut: "未登录"
        case .ready: "已登录"
        }
    }

    private var moviePilotActionButtonTitle: String {
        moviepilot.store.serverURLString == nil ? "设置…" : "修改…"
    }
}
