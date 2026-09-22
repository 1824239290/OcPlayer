import AppDesignKit
import DanmakuKit
import JellyfinKit
import DiagnosticsKit
import SwiftUI

/// 设置页，六组：通用 / 播放（含播放内核）/ 弹幕 / 服务（Jellyfin·Bangumi·MoviePilot）/ 关于 / 维护。
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
    /// 海报氛围背景开关（默认开）：DetailView / AmbientBackdropCarousel 读同一 key，
    /// 改了立即生效。
    @AppStorage(SettingsKeys.ambientBackdrop) private var ambientBackdropEnabled = true
    /// Bangumi / MoviePilot 集成开关（默认开）。关闭后侧栏入口、详情页区块与
    /// 后台同步一并隐藏/停止，凭据与关联数据保留（见各功能触点的门控）。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true
    /// 跳过片头/片尾开关（默认开）与保底片尾保留秒数（默认 10）。与
    /// PlaybackPreferences 同 key，播放中改动即生效（提示按钮每拍进度重读）。
    @AppStorage(SettingsKeys.skipIntro) private var skipIntroEnabled = true
    @AppStorage(SettingsKeys.skipOutro) private var skipOutroEnabled = true
    @AppStorage(SettingsKeys.outroRetentionSeconds) private var storedOutroRetention = 10
    private var outroRetentionSeconds: Int {
        PlaybackPreferences.outroRetentionOptionsSeconds.contains(storedOutroRetention)
            ? storedOutroRetention : 10
    }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("海报氛围背景", isOn: $ambientBackdropEnabled)
                Text("详情页与首页垫模糊海报背景，关闭后恢复清晰横幅。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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
            }

            Section("Jellyfin 服务器") {
                KeyValueRow(label: "名称", value: app.server?.profile.serverName ?? "—")
                KeyValueRow(label: "地址", value: app.server?.profile.baseURL.absoluteString ?? "—")
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
                NavigationLink {
                    ServersView()
                } label: {
                    Label("管理服务器…", systemImage: "list.bullet")
                }
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

            Section("Bangumi") {
                Toggle("启用 Bangumi", isOn: $bangumiEnabled)
                if bangumiEnabled {
                    KeyValueRow(label: "账号", value: bangumi.profile?.nickname ?? "未登录")
                    if !bangumi.isAuthenticated {
                        Text("登录入口在侧栏的 Bangumi 分区。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("关闭后侧栏与详情页的 Bangumi 入口会隐藏；登录状态与条目关联保留。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

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
                    if moviepilot.isAuthenticated {
                        Button(role: .destructive) {
                            Task { await moviepilot.signOut() }
                        } label: {
                            Label("退出 MoviePilot", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Text("关闭后侧栏与详情页的 MoviePilot 入口会隐藏；服务器配置保留。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("关于") {
                KeyValueRow(label: "版本", value: AppVersion.displayString)
                UpdateCheckRow(
                    checker: updateChecker,
                    onShowRelease: { release in
                        presentedRelease = release
                    }
                )
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    LabeledContent(
                        "开源许可证",
                        value: "\(OpenSourceLicenseCatalog.componentCount) 个项目"
                    )
                }
            }

            Section {
                ImageCacheSettingsRow()
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
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
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

    /// 状态行纯展示（点击不弹窗），操作按钮独立放置——与弹幕网关区块同规矩。
    private var moviePilotStatusText: String {
        let mp = moviepilot
        if mp.store.serverURLString == nil { return "未配置" }
        if mp.isAuthenticated { return "已登录" }
        return mp.store.isConfigured ? "未登录" : "凭据不全"
    }

    private var moviePilotActionButtonTitle: String {
        moviepilot.store.serverURLString == nil ? "设置…" : "修改…"
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
