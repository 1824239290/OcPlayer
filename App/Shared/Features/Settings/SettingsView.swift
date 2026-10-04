import AppDesignKit
import DanmakuKit
import JellyfinKit
import DiagnosticsKit
import MetadataKit
import SwiftUI

/// 设置页，六组：播放（含播放内核）/ 弹幕 / 网络 / 服务（Jellyfin·Bangumi·MoviePilot）/ 关于 / 维护。
/// 原则：这里只放设置——播放入口在首页工具栏与 macOS 文件菜单，工程说明不进设置页，
/// 说明文字一行为辄。服务器列表的切换 / 删除收在「管理服务器」子页（`ServersView`）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(DanmakuModel.self) private var danmakuModel

    @State private var isEditingDanmakuGateway = false
    @State private var isEditingMoviePilot = false
    /// 单例是引用类型，不需要 @State 的存储语义；let 即可（@Observable 变化照常驱动刷新）。
    private let updateChecker = AppUpdateChecker.shared
    @State private var presentedRelease: GitHubRelease?

    /// pushPresented 两段式的落地标志（管理服务器 / 开源许可证）。
    @State private var showServers = false
    @State private var showLicenses = false
    /// 启动默认服务器的本地镜像。`ServerStore` 不是 `@Observable`，
    /// Picker 需要这份 @State 驱动选中态刷新；持久化仍以 store 为准。
    @State private var selectedDefaultServerID: String?
    /// 预读档位的选中值：直接绑 UserDefaults 的原始 key（@AppStorage 可观察，
    /// 别处改了 Picker 也会刷新）。非法值显示为 0（与 PlaybackPreferences 的
    /// 读取校验一致）；Picker 只写合法档位。
    @AppStorage(SettingsKeys.httpReadAheadMiB) private var storedReadAheadMiB = 0
    private var readAheadMiB: Int {
        PlaybackPreferences.readAheadOptionsMiB.contains(storedReadAheadMiB) ? storedReadAheadMiB : 0
    }
    /// 回退缓冲档位：同预读档位的 @AppStorage 套路。
    @AppStorage(SettingsKeys.httpBackBufferMiB) private var storedBackBufferMiB = 0
    private var backBufferMiB: Int {
        PlaybackPreferences.backBufferOptionsMiB.contains(storedBackBufferMiB) ? storedBackBufferMiB : 0
    }
    /// 弹幕诊断日志开关（默认关闭）：与 PlaybackPreferences.danmakuDiagnosticsEnabled
    /// 同一 key，@AppStorage 双向可观察，改了立即生效。
    @AppStorage(SettingsKeys.danmakuDiagnostics) private var danmakuDiagnosticsEnabled = false
    /// Bangumi / MoviePilot 集成开关（默认开）。关闭后顶栏入口、详情页区块与
    /// 后台同步一并隐藏/停止，凭据与关联数据保留（见各功能触点的门控）。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true
    /// 跳过片头/片尾开关（默认开）与保底片尾保留秒数（默认 10）。与
    /// PlaybackPreferences 同 key，播放中改动即生效（提示按钮每拍进度重读）。
    @AppStorage(SettingsKeys.skipIntro) private var skipIntroEnabled = true
    @AppStorage(SettingsKeys.skipOutro) private var skipOutroEnabled = true
    @AppStorage(SettingsKeys.outroRetentionSeconds) private var storedOutroRetention = 10
    /// 自定义 User-Agent（空 = 系统默认）。与 `ClientIdentity`（JellyfinKit）同 key，
    /// 三条请求发送口每条即时读取，改完不需要重连。**全局**，不按服务器档案分——
    /// 所以 UI 放在「网络」分组，不塞进某一台服务器的分组里。
    @AppStorage(ClientIdentity.customUserAgentKey) private var customUserAgent = ""
    /// 首页栏目顺序与显隐。原始串经 `HomeSectionPreference` 编解码；
    /// @AppStorage 可观察，改完首页即时生效。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw
    private var homeSections: [HomeSection] { HomeSectionPreference.decode(homeSectionsRaw) }
    private var outroRetentionSeconds: Int {
        PlaybackPreferences.outroRetentionOptionsSeconds.contains(storedOutroRetention)
            ? storedOutroRetention : 10
    }

    var body: some View {
        Form {

            Section("首页栏目") {
                ForEach(homeSections) { section in
                    homeSectionRow(section)
                }
                Text("拖动条目或用上下按钮调整顺序，开关控制显示与隐藏。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            Section("播放") {
                Picker("网络预读缓冲", selection: Binding(
                    get: { readAheadMiB },
                    set: { storedReadAheadMiB = $0 }
                )) {
                    ForEach(PlaybackPreferences.readAheadOptionsMiB, id: \.self) { mib in
                        Text(mib == 0 ? "默认（2 MiB）" : "\(mib) MiB").tag(mib)
                    }
                }
                // 内核用持久流预取（开放式 GET 长连接，背压就是 TCP），档位不再
                // 对应带宽门槛：深度只影响内存占用与抗卡顿能力，弱网下无需刻意调小。
                Text("数值越大越能抗带宽抖动，内存占用相应增加。内核用持久流预取，弱网下无需刻意调小。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Picker("回退缓冲", selection: Binding(
                    get: { backBufferMiB },
                    set: { storedBackBufferMiB = $0 }
                )) {
                    ForEach(PlaybackPreferences.backBufferOptionsMiB, id: \.self) { mib in
                        Text(mib == 0 ? "默认（16 MiB）" : "\(mib) MiB").tag(mib)
                    }
                }
                // 回退预算与码率挂钩：16 MiB 在 71 Mbps 下只够 -1.8 秒，
                // 高码率片源想随意回退 10 秒需要 ~89 MB。低码率番剧默认档已够数分钟。
                Text("已播内容保留在缓存里，回退落在这段内不发网络请求。高码率片源建议调大（16 MiB 在 70 Mbps 下只够回退约 2 秒）。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("跳过片头", isOn: $skipIntroEnabled)
                Toggle("跳过片尾", isOn: $skipOutroEnabled)
                Picker("片尾保留", selection: Binding(
                    get: { outroRetentionSeconds },
                    set: { storedOutroRetention = $0 }
                )) {
                    ForEach(PlaybackPreferences.outroRetentionOptionsSeconds, id: \.self) { seconds in
                        Text(seconds == 0 ? "不保留" : "\(seconds) 秒").tag(seconds)
                    }
                }
                .disabled(!skipOutroEnabled)
                Text("播放到片头/片尾时出现「跳过」按钮；片尾保留指保底跳过后停在片尾结束前多久，不保留则直接跳到片尾尽头。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            PlaybackKernelSection()

            Section("弹幕") {
                Toggle("自动加载弹幕", isOn: Binding(
                    get: { danmakuModel.danmaku.isAutoLoadingEnabled },
                    set: { app.setDanmakuAutoLoadingEnabled($0) }
                ))
                HStack {
                    Text("网关")
                    Spacer()
                    Text(danmakuModel.dandanplayIsConfigured
                         ? danmakuModel.dandanplayGatewayURLString : "未配置")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("配置") {
                        isEditingDanmakuGateway = true
                    }
                }
                if !danmakuModel.dandanplayIsConfigured {
                    Text("未配置网关时不请求网络弹幕，播放不受影响。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                TextField("anime-skip Client ID（可选）", text: Binding(
                    get: { danmakuModel.animeSkipClientID },
                    set: { danmakuModel.animeSkipClientID = $0 }
                ))
                Text("填入后启用 anime-skip 跳过片头源（在 anime-skip.com 注册获取）。TheIntroDB 免密钥自动启用。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            Section("网络") {
                TextField("自定义 User-Agent（可选）", text: $customUserAgent, prompt: Text("留空使用默认"))
                    .textFieldStyle(.roundedBorder)
                Text("部分服务器开了播放器白名单，会把非白名单客户端的请求拒之门外；填入白名单内的播放器 UA（如 SenPlayer 的）即可通过。对所有服务器生效，浏览与拉流即时生效、无需重连；控制字符会被剔除。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            Section("Jellyfin 服务器") {
                KeyValueRow(label: "名称", value: app.server?.profile.serverName ?? "—")
                KeyValueRow(
                    label: "地址",
                    value: (app.serverEndpointURL ?? app.server?.profile.baseURL)?.absoluteString ?? "—"
                )
                if let profile = app.server?.profile, !profile.addresses.isEmpty {
                    serverAddressNote(profile)
                }
                if !app.store.profiles.isEmpty {
                    Picker("启动时默认服务器", selection: defaultServerBinding) {
                        Text("上次使用的服务器").tag(String?.none)
                        ForEach(app.store.profiles) { profile in
                            Text(profile.serverName + " · " + profile.kind.displayName)
                                .tag(String?.some(profile.id))
                        }
                    }
                    Text("打开 App 时优先连接这台。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // 换服务器不等于退出登录：`ServerStore` 是按 profile 存的，
                // 回登录流程连另一台就行，旧档案还在（登录页上「先不登录」可以退回来）。
                Button {
                    app.pushPresented { showServers = true }
                } label: {
                    Label("管理服务器…", systemImage: "list.bullet")
                }
                .buttonStyle(.plain)
                Button {
                    app.reconnectFlow()
                } label: {
                    Label(
                        app.server == nil ? "连接服务器…" : "连接其它服务器…",
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                Button(role: .destructive) {
                    app.signOut()
                } label: {
                    Label("退出 Jellyfin", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .settingsRowBackground()

            Section("Bangumi") {
                Toggle("启用 Bangumi", isOn: $bangumiEnabled)
                if bangumiEnabled {
                    KeyValueRow(label: "账号", value: bangumiAccountText)
                    if bangumi.isAuthenticated {
                        // 退出登录原先只有 Bangumi 分区「我的」页顶栏一个出口：要退得先
                        // 切到那个分区、再进个人页，设置页里找不到——与 Jellyfin /
                        // MoviePilot 的出口位置对齐，这里补一个。
                        Button(role: .destructive) {
                            Task { await bangumi.signOut() }
                        } label: {
                            Label("退出 Bangumi", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Text("登录入口在顶栏的 Bangumi 分区。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("关闭后顶栏与详情页的 Bangumi 入口会隐藏；登录状态与条目关联保留。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .settingsRowBackground()

            Section("MoviePilot") {
                Toggle("启用 MoviePilot", isOn: $moviepilotEnabled)
                if moviepilotEnabled {
                    KeyValueRow(label: "地址", value: moviepilot.store.serverURLString ?? "—")
                    KeyValueRow(label: "用户", value: moviepilot.profile?.name
                        ?? (moviepilot.store.username.isEmpty ? "—" : moviepilot.store.username))
                    KeyValueRow(label: "状态", value: moviePilotStatusText)
                    Button(moviePilotActionButtonTitle) {
                        isEditingMoviePilot = true
                    }
                    // 默认关：密码不落盘。打开后存进凭据文件（已排除备份），
                    // 换来 JWT 8 天过期后的静默重登。
                    Toggle("记住密码（令牌过期后免重输）", isOn: Binding(
                        get: { moviepilot.rememberPassword },
                        set: { moviepilot.rememberPassword = $0 }))
                    Text("MoviePilot 的登录令牌 8 天过期且无法刷新。默认不保存密码："
                        + "到期后需要重新输入一次。打开此项会把密码存到本机凭据文件"
                        + "（已排除 iCloud / Time Machine 备份）。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if moviepilot.isAuthenticated {
                        Button(role: .destructive) {
                            Task { await moviepilot.signOut() }
                        } label: {
                            Label("退出 MoviePilot", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Text("关闭后顶栏与详情页的 MoviePilot 入口会隐藏；服务器配置保留。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .settingsRowBackground()

            Section("TMDb 元数据补全") {
                TMDbSettingsSection()
            }
            .settingsRowBackground()

            Section("关于") {
                KeyValueRow(label: "版本", value: AppVersion.displayString)
                UpdateCheckRow(
                    checker: updateChecker,
                    onShowRelease: { release in
                        presentedRelease = release
                    }
                )
                Button {
                    app.pushPresented { showLicenses = true }
                } label: {
                    LabeledContent(
                        "开源许可证",
                        value: "\(OpenSourceLicenseCatalog.componentCount) 个项目"
                    )
                }
                .buttonStyle(.plain)
            }
            .settingsRowBackground()

            Section {
                ImageCacheSettingsRow()
                MetadataCacheSettingsRow()
                Toggle("弹幕诊断日志", isOn: $danmakuDiagnosticsEnabled)
                Text("排查弹幕时间轴错位等问题时再开，平时保持关闭。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                DiagnosticsSection()
            } header: {
                Text("维护")
            } footer: {
                Text("日志写入 \(AppDiagnostics.fileURL.path)，含脱敏后的 token / 路径信息；需要完整上下文请导出后发送。")
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .formStyle(.grouped)
        // view-destination 页面走 pushPresented 两段式（淡出后落地），与路由页一致；
        // `presented:` 把落地开关交给自绘返回键——这类页面不在 `path` 上，
        // 不交就只有「点返回没反应」（见 AppModel.popPresented）。
        .navigationDestination(isPresented: $showServers) {
            ServersView()
                .appShellBackChrome(title: "管理服务器", presented: $showServers)
                .pageEntrance()
        }
        .navigationDestination(isPresented: $showLicenses) {
            OpenSourceLicensesView()
                .appShellBackChrome(title: "开源许可证", presented: $showLicenses)
                .pageEntrance()
        }
        // 呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖：落地期间
        // 整页隐去，别透过半透的服务器 / 许可证页漏出（见 coveredByPresented）。
        .coveredByPresented($showServers, $showLicenses)
        .onAppear {
            selectedDefaultServerID = app.store.defaultServerID
        }
        .sheet(isPresented: $isEditingDanmakuGateway) {
            DanmakuGatewayEntrySheet(
                initialURL: danmakuModel.dandanplayGatewayURLString,
                initialKey: danmakuModel.dandanplayAPIKey
            ) { url, key in
                Task { await app.updateDanmakuGateway(urlString: url, apiKey: key) }
            }
        }
        .sheet(isPresented: $isEditingMoviePilot) {
            MoviePilotServerSheet(
                initialURL: moviepilot.store.serverURLString ?? "",
                initialUsername: moviepilot.store.username
            )
        }
        .sheet(item: $presentedRelease) { release in
            UpdateReleaseSheet(release: release)
        }
        .task {
            // 停用的集成不做任何启动期网络活动（profile 校验也跳过）。
            if moviepilotEnabled {
                moviepilot.refreshProfileIfNeeded()
            }
            if updateChecker.state == .idle {
                await updateChecker.checkForUpdates()
            }
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

    // MARK: - 首页栏目

    /// 一行：栏目名 + 上移/下移 + 显隐开关。用按钮排序而不是 List.onMove：
    /// grouped Form 里 onMove 要 iOS 的编辑态，macOS 没有对应入口，按钮双端一致。
    private func homeSectionRow(_ section: HomeSection) -> some View {
        let index = homeSections.firstIndex(of: section)
        return HStack(spacing: 14) {
            Label(section.title, systemImage: Self.sectionIcon(section))

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button {
                    moveHomeSection(section, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("上移\(section.title)")

                Button {
                    moveHomeSection(section, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == homeSections.count - 1)
                .accessibilityLabel("下移\(section.title)")
            }
            .buttonStyle(.borderless)

            Toggle("", isOn: sectionEnabledBinding(section))
                .labelsHidden()
                .accessibilityLabel("显示\(section.title)")
        }
    }

    private func moveHomeSection(_ section: HomeSection, offset: Int) {
        var sections = homeSections
        guard let index = sections.firstIndex(of: section) else { return }
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.swapAt(index, target)
        homeSectionsRaw = HomeSectionPreference.encode(sections)
    }

    /// 显隐开关：开启 = 追加到列表末尾（用上下按钮再挪位置），关闭 = 移出列表。
    private func sectionEnabledBinding(_ section: HomeSection) -> Binding<Bool> {
        Binding(
            get: { homeSections.contains(section) },
            set: { on in
                var sections = homeSections
                if on {
                    guard !sections.contains(section) else { return }
                    sections.append(section)
                } else {
                    // 全关掉首页只剩空态，是用户的明确选择，不拦。
                    sections.removeAll { $0 == section }
                }
                homeSectionsRaw = HomeSectionPreference.encode(sections)
            }
        )
    }

    private static func sectionIcon(_ section: HomeSection) -> String {
        switch section {
        case .resume: "play.circle"
        case .nextUp: "arrow.right.circle"
        case .latest: "clock"
        case .libraries: "square.stack"
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

    /// 多地址服务器的说明。只有一个入口时没什么可说，有备选地址才提
    /// 「自动择优 / 已固定」，并指出这些都能在「管理服务器」里改。
    @ViewBuilder
    private func serverAddressNote(_ profile: ServerProfile) -> some View {
        let active = (app.serverEndpointURL ?? profile.baseURL).absoluteString
        if let pinned = profile.pinnedURL {
            Text("已固定使用 \(pinned.absoluteString)，不会自动切换。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text("共 \(profile.allAddresses.count) 个地址：自动选择最快的（现在用的是 \(active)）；可在「管理服务器」里添加、删除或固定地址。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Bangumi 账号行：以 `isAuthenticated` 为准（它是登录的唯一门控信号）。
    /// 资料还没拉回来时 profile 为 nil，直接读它会显示成「未登录」——而旁边
    /// 就摆着「退出 Bangumi」，两行互相打架。
    private var bangumiAccountText: String {
        if let profile = bangumi.profile { return profile.name }
        return bangumi.isAuthenticated ? "已登录" : "未登录"
    }
}

private struct ImageCacheSettingsRow: View {
    @State private var usageText = "—"
    @State private var isClearing = false

    var body: some View {
        LabeledContent("图片缓存", value: usageText)
            .onAppear(perform: refresh)

        Button(role: .destructive) {
            clearCache()
        } label: {
            Label("清空图片缓存", systemImage: "trash")
        }
        .disabled(isClearing)
    }

    private func clearCache() {
        isClearing = true
        Task {
            await Task.detached(priority: .utility) {
                ImagePipeline.shared.clearCache()
            }.value
            refresh()
            isClearing = false
        }
    }

    private func refresh() {
        let usage = ImagePipeline.shared.diskUsage
        usageText = "\(Self.format(usage.usedBytes)) / \(Self.format(usage.capacityBytes))"
    }

    private static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 媒体元数据缓存（SQLite）的体积与出口。
///
/// 与图片缓存分开两行而不是合并成「缓存」一项：两者的**代价完全不同**——
/// 清图片缓存只是下次重新下载图（几秒的事），清元数据库会让下次冷启动回到
/// 「等网络」的状态（离线时尤其明显）。合成一项，用户点之前不知道自己在放弃什么。
private struct MetadataCacheSettingsRow: View {
    @Environment(AppModel.self) private var app
    @State private var isClearing = false
    @State private var cleared = false

    var body: some View {
        LabeledContent("媒体元数据缓存", value: usageText)
            .onAppear { app.metadata.refreshSize() }

        HStack {
            Button(role: .destructive) {
                clear()
            } label: {
                Label(cleared ? "已清空" : "清空媒体元数据缓存", systemImage: "trash")
            }
            .disabled(isClearing)
            if cleared {
                Text("下次进首页/详情会重新拉取")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 数据库体积；未建库（启动早期 / 建库失败）时显示占位而不是 0。
    private var usageText: String {
        if let error = app.metadata.setupError { return "不可用" }
        guard app.metadata.isReady else { return "—" }
        return Self.format(app.metadata.databaseBytes)
    }

    private func clear() {
        isClearing = true
        Task {
            _ = await app.metadata.clearCurrentTenant()
            cleared = true
            isClearing = false
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 弹幕网关地址与 API Key 编辑弹窗。Key 留空表示停用网络弹幕。
struct DanmakuGatewayEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gatewayURL: String
    @State private var key: String
    let onSubmit: (String, String) -> Void

    init(initialURL: String, initialKey: String, onSubmit: @escaping (String, String) -> Void) {
        _gatewayURL = State(initialValue: initialURL)
        _key = State(initialValue: initialKey)
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("网关地址")
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            "",
                            text: $gatewayURL,
                            prompt: Text("https://gateway.example.com")
                        )
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        Text("仅支持 HTTPS 根地址；留空恢复默认网关。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.subheadline.weight(.semibold))
                        SecureField(
                            "",
                            text: $key,
                            prompt: Text("由网关管理员签发")
                        )
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        Text("Key 只通过 X-API-Key 请求头发送，不写入播放地址或诊断日志。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("弹幕网关")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSubmit(
                            gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            key.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!gatewayURLIsValid)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 340)
        #endif
    }

    private var gatewayURLIsValid: Bool {
        let value = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || DandanplaySettingsStore.normalizedURL(from: value) != nil
    }
}

// MARK: - 诊断

/// 设置页的诊断区：详细日志开关 / 导出诊断包 / 日志路径 / 最近记录（可滚动）/ 清空。
/// 导出的是**单个 .txt**（头部说明 + 全部 JSONL 记录），报告问题时直接附件。
struct DiagnosticsSection: View {
    /// 详细（debug）档开关：只影响日志管线的最低落盘级别，与播放/弹幕开关无关。
    @AppStorage(SettingsKeys.diagnosticsVerbose) private var verboseLogging = false
    @State private var records: [DiagnosticEntry] = []
    @State private var summaryText = "—"
    @State private var revealPath = false
    @State private var exportDocument: DiagnosticExportDocument?
    @State private var isExporting = false
    @State private var exportFailure: String?

    var body: some View {
        Toggle("详细日志", isOn: $verboseLogging)
            .onChange(of: verboseLogging) { _, _ in
                // 立即生效：改的是日志管线的进程级最低级别，不需要重启。
                DiagnosticsSettings.apply()
            }

        Text("打开后记录 debug 级链路细节（守卫拒绝、中间态）并打开内核 trace"
            + "（HTTP 逐请求 / 播放读失败 / HDR 调试，**下一次播放生效**）；"
            + "关闭时只记状态迁移与失败。")
            .font(.caption)
            .foregroundStyle(.secondary)

        Button {
            revealPath.toggle()
        } label: {
            HStack {
                Text("日志文件")
                Spacer()
                Text(revealPath ? AppDiagnostics.fileURL.path : AppDiagnostics.fileURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)

        KeyValueRow(label: "记录数 / 大小", value: summaryText)
            .task { await refresh() }

        DisclosureGroup("最近 \(records.count) 条记录") {
            if records.isEmpty {
                Text("暂无日志记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.message)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(Self.meta(record))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .font(.caption)

        Button {
            export()
        } label: {
            Label("导出诊断包…", systemImage: "square.and.arrow.up")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: DiagnosticsExport.suggestedFileName()
        ) { result in
            if case .failure(let error) = result {
                exportFailure = "导出失败：\(error.localizedDescription)"
            }
        }
        if let exportFailure {
            Text(exportFailure)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button(role: .destructive) {
            try? AppDiagnostics.logger.clear()
            Task { await refresh() }
        } label: {
            Label("清空日志", systemImage: "trash")
        }
    }

    /// 导出内容要读整份日志（可能几 MB），挪出主线程再回来开面板（同 refresh 的做法）。
    private func export() {
        Task {
            let result: (text: String?, failure: String?) = await Task.detached {
                do { return (try DiagnosticsExport.makeText(), nil) }
                catch { return (nil, error.localizedDescription) }
            }.value
            if let text = result.text {
                exportDocument = DiagnosticExportDocument(text: text)
                exportFailure = nil
                isExporting = true
            } else {
                exportFailure = "导出失败：\(result.failure ?? "未知错误")"
            }
        }
    }

    /// 读日志要碰磁盘（尾部解码 + 换行统计），挪出主线程再回来赋值，
    /// 打开设置页不会因为日志攒大了而卡一下。
    private func refresh() async {
        let snapshot = await Task.detached {
            let records = AppDiagnostics.recentRecords
            let summary = AppDiagnostics.logger.summary()
            return (records, summary)
        }.value
        records = snapshot.0
        if let summary = snapshot.1 {
            let size = ByteCountFormatter.string(
                fromByteCount: summary.fileSizeBytes,
                countStyle: .file
            )
            summaryText = "\(summary.recordCount) 条 · \(size)"
        } else {
            summaryText = "0 条"
        }
    }

    /// 每条记录现场造一个 DateFormatter 会创建几十个对象；样式固定，直接共享一个。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // 固定格式串必须配固定 locale，否则某些区域会用本地数字符号渲染时间。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func meta(_ record: DiagnosticEntry) -> String {
        var parts = ["\(record.level.uppercased())", timeFormatter.string(from: record.timestamp)]
        if let suppressed = record.suppressed, suppressed > 0 {
            parts.append("(另抑制 \(suppressed) 条)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 检查更新行

private struct UpdateCheckRow: View {
    let checker: AppUpdateChecker
    let onShowRelease: (GitHubRelease) -> Void

    var body: some View {
        HStack {
            Text("检查更新")
            Spacer()

            switch checker.state {
            case .idle:
                Button("检查") {
                    Task { await checker.checkForUpdates(isUserInitiated: true) }
                }

            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .upToDate:
                HStack(spacing: 8) {
                    Text("已是最新")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新检查") {
                        Task { await checker.checkForUpdates(isUserInitiated: true) }
                    }
                    .font(.callout)
                }

            case .updateAvailable(let release):
                HStack(spacing: 6) {
                    Button {
                        onShowRelease(release)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.tint)
                            Text(checker.ignoredVersion == release.tagName ? "发现新版本 \(release.tagName) (已忽略)" : "发现新版本 \(release.tagName)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                    .buttonStyle(.borderless)
                }

            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Button("重试") {
                        Task { await checker.checkForUpdates(isUserInitiated: true) }
                    }
                    .font(.callout)
                }
            }
        }
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

// MARK: - TMDb 元数据补全

/// TMDb 补全的设置区块。
///
/// 设计上刻意与「媒体元数据缓存」分开两处：
/// - 那一行是**缓存**（服务端数据的副本，清掉只是重新拉）；
/// - 这一块是**补全**（用第三方数据增强展示，清掉会丢掉「哪条对应到哪」的判断）。
///
/// 合成一项的话，用户点「清除 TMDb 数据」时并不知道自己放弃的是后者。
private struct TMDbSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var keyInput = ""
    @State private var isClearing = false
    @State private var cleared = false

    private var tmdb: TMDbCoordinator { app.tmdb }

    var body: some View {
        // 没有「启用」开关：**留空即禁用**（与 anime-skip Client ID 一致）。
        // 一个「打开」的开关若在 key 为空时什么都不做，用户会以为坏了；
        // 而「清掉 key」本身就等于停用，不需要第二个状态位。
        HStack {
            SecureField("TMDB API Key 或 Read Access Token", text: $keyInput)
                .textFieldStyle(.roundedBorder)
            Button(tmdb.isConfigured ? "替换" : "保存") {
                tmdb.setAPIKey(keyInput)
                keyInput = ""
                cleared = false
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // 「已补全条目」与错误提示都要进页面时取一次——原先没有任何地方调它，
        // 于是那一行**恒显示 0**（看着像功能没生效）。
        //
        // 挂在第一个 HStack 上而不是末尾的 `if` 块上：`.onAppear` 直接接在 `if`
        // 块后面时 Swift 会把 `.` 解析成新语句（报 "cannot be used on type 'View'"）。
        // 这个 HStack 无条件渲染，挂它上面两条分支都能触发。
        .onAppear {
            Task {
                await app.refreshTMDbLinkCount()
                await tmdb.refreshLastFailure()
            }
        }

        if tmdb.isConfigured {
            KeyValueRow(label: "当前 Key", value: tmdb.apiKeyDisplay)
        } else {
            Text("填入后启用 TMDb 补全：用第三方元数据补充详情页的简介、评分、演员与海报。"
                 + "留空 = 关闭，不请求、不影响任何现有功能。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        Text("在 themoviedb.org 的账户设置里生成（免费）。v3 API Key 与 v4 Read Access Token 都支持，粘贴哪个都行。")
            .font(.caption)
            .foregroundStyle(.tertiary)
        Text("需要能直连 api.themoviedb.org，图片走 image.tmdb.org（国内网络通常需要代理）。")
            .font(.caption)
            .foregroundStyle(.tertiary)

        if tmdb.isConfigured {
            Picker("语言", selection: Binding(
                get: { tmdb.language },
                set: { tmdb.setLanguage($0) })) {
                ForEach(TMDbLanguageOption.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            Text("标题与简介按此语言取；该语言缺翻译的字段自动回退到英文。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Toggle("文本以 TMDb 优先", isOn: Binding(
                get: { tmdb.preferText },
                set: { tmdb.setPreferText($0) }))
            Text(tmdb.preferText
                 ? "标题/简介/类型用 TMDb 的替换服务端的。"
                 : "只补服务端缺的字段，已有的不动。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Toggle("用 TMDb 图片替换已有的图", isOn: Binding(
                get: { tmdb.replaceImages },
                set: { tmdb.setReplaceImages($0) }))
            Text(tmdb.replaceImages
                 ? "海报/背景/分集剧照优先用 TMDb 的（服务端已有的图会被顶掉）。"
                 : "只补服务端没有图的条目；已精修过的海报不会被覆盖。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            LabeledContent("已补全条目", value: "\(tmdb.linkedCount)")

            // 库级批量补全：不用一个个点开详情页。
            batchSection

            // 坏 key / 网络不通原先**完全静默**：用户填了 key 却什么都没发生，
            // 只会以为功能坏了。这里把最近一次失败摆出来。
            if let failure = tmdb.lastError {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(role: .destructive) {
                    clear()
                } label: {
                    Label(cleared ? "已清除" : "清除 TMDb 补全数据", systemImage: "trash")
                }
                .disabled(isClearing)
                if cleared {
                    Text("对应关系与已下载的 TMDb 数据已删除")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("缓存上限 \(tmdb.cacheLifetimeDescription)（TMDb 条款要求不超过 \(tmdb.maxCacheDays) 天）。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // TMDb 的署名要求。完整条款在 OpenSourceLicensesView 的「社区数据与服务」分组。
            Text("本产品使用 TMDb API，但未获得 TMDb 认可或认证。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
    private func clear() {
        isClearing = true
        Task {
            await tmdb.clear(tenant: app.currentTenant)
            cleared = true
            isClearing = false
        }
    }

    /// 库级批量补全：一次把整库的电影/剧（连同各季）补齐，不用一个个点开详情页。
    ///
    /// 四类计数分开显示（新补 / 跳过 / 匹配不上 / 失败）：混成一个「成功 N 条」的话，
    /// 用户不知道剩下那些该怎么办——「匹配不上」要他去手动匹配，「失败」要去看网络。
    @ViewBuilder
    private var batchSection: some View {
        if tmdb.isBatching {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: tmdb.batchProgress?.fraction ?? 0) {
                    Text(batchStatusText)
                        .font(.caption)
                }
                if let progress = tmdb.batchProgress {
                    Text("新补 \(progress.enriched) · 跳过 \(progress.skipped)"
                         + " · 匹配不上 \(progress.unmatched) · 失败 \(progress.failed)"
                         + (progress.seasons > 0 ? " · 剧集季 \(progress.seasons)" : ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("取消补全", role: .cancel) { tmdb.cancelBatch() }
            }
        } else {
            HStack {
                Button {
                    app.enrichTMDbLibrary()
                } label: {
                    Label("补全整个媒体库", systemImage: "wand.and.stars")
                }
                .disabled(!tmdb.isReady)
                if let result = tmdb.lastBatchResult {
                    Text(batchSummary(result))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("逐条匹配并拉取简介、评分、演员与图片；剧集连同各季一起补（分集标题与剧照需要季数据）。中途取消或退出后再点一次会接着做——已经补好的不会重复请求。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        if let error = tmdb.batchError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var batchStatusText: String {
        guard let progress = tmdb.batchProgress else { return "正在准备…" }
        let head = "正在补全 \(progress.completed)/\(progress.total)"
        guard let title = progress.currentTitle, !title.isEmpty else { return head }
        return "\(head)：\(title)"
    }

    private func batchSummary(_ result: TMDbBatchResult) -> String {
        if result.wasCancelled {
            return "已取消（处理了 \(result.processed)/\(result.total) 条）"
        }
        return "上次：新补 \(result.enriched) · 跳过 \(result.skipped)"
            + " · 匹配不上 \(result.unmatched) · 失败 \(result.failed)"
    }
}
