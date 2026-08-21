import DanmakuKit
import DiagnosticsKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置页：服务器与账号信息、本地播放入口、弹幕网关、关于信息。
/// 外观 / 播放细节设置 M4 再进。
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var isImporting = false
    @State private var isEnteringURL = false
    @State private var isEditingDanmakuGateway = false

    var body: some View {
        Form {
            Section("服务器") {
                row("名称", app.server?.profile.serverName ?? "—")
                row("地址", app.server?.profile.baseURL.absoluteString ?? "—")
                row("版本", app.server?.profile.serverVersion ?? "—")
                row("用户", app.currentUserLabel)
                // 换服务器不等于退出登录：`ServerStore` 是按 profile 存的，
                // 回登录流程连另一台就行，旧档案还在（登录页上「先不登录」可以退回来）。
                Button {
                    app.reconnectFlow()
                } label: {
                    Label(
                        app.server == nil ? "连接服务器…" : "连接其它服务器…",
                        systemImage: "arrow.left.arrow.right"
                    )
                }
            }

            Section("播放") {
                Button {
                    isImporting = true
                } label: {
                    Label("打开本地视频文件…", systemImage: "folder")
                }
                Button {
                    isEnteringURL = true
                } label: {
                    Label("打开直连链接…", systemImage: "link")
                }
                Text("直连播放 token 只走请求头；本地文件不上传任何信息。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("弹幕") {
                Toggle("自动加载弹幕", isOn: Binding(
                    get: { app.danmaku.isAutoLoadingEnabled },
                    set: { app.setDanmakuAutoLoadingEnabled($0) }
                ))
                HStack {
                    Text("网关")
                    Spacer()
                    Text(app.dandanplayGatewayURLString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("配置") {
                        isEditingDanmakuGateway = true
                    }
                }
                LabeledContent("API Key", value: app.dandanplayHasAPIKey ? "已设置" : "未设置")
                LabeledContent("状态", value: app.dandanplayIsConfigured ? "已配置" : "未配置")
                Text("网关地址或 Key 未配置有效时不会请求弹幕，也不会影响视频播放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                row("播放内核", "Erika（Rust · FFmpeg · libass）")
                row("直连策略", "优先直连直解（DirectPlay），播放前经 PlaybackInfo 选择媒体源；不支持直连的源回退直连流（DirectStream）")
                row("弹幕", "弹弹play 开放平台（通过 OcPlay 网关接入）")
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    LabeledContent(
                        "开源许可证",
                        value: "\(OpenSourceLicenseCatalog.componentCount) 个项目"
                    )
                }
            }

            Section("存储") {
                ImageCacheSettingsRow()
            }

            Section {
                DiagnosticsSection()
            } header: {
                Text("诊断")
            } footer: {
                Text("日志写入 \(AppDiagnostics.fileURL.path)，含脱敏后的 token / 路径信息；需要完整上下文请导出后发送。")
            }

            Section {
                Button(role: .destructive) {
                    app.signOut()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: Self.playableTypes) { result in
            if case .success(let url) = result { openLocal(url) }
        }
        .sheet(isPresented: $isEnteringURL) {
            URLEntrySheet { uri, token in
                openDirect(uri, token: token)
            }
        }
        .sheet(isPresented: $isEditingDanmakuGateway) {
            DanmakuGatewayEntrySheet(
                initialURL: app.dandanplayGatewayURLString,
                initialKey: app.dandanplayAPIKey
            ) { url, key in
                app.updateDanmakuGateway(urlString: url, apiKey: key)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func openLocal(_ url: URL) {
        app.presentLocalFile(url)
    }

    private func openDirect(_ uri: String, token: String?) {
        app.presentRequest(PlaybackController.request(uri: uri, jellyfinToken: token))
    }

    private static var playableTypes: [UTType] {
        [.audiovisualContent, .movie, .video, .mpeg4Movie, .quickTimeMovie]
            + [UTType("org.matroska.mkv")].compactMap { $0 }
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

/// 直连链接入口（M0 验证 `open_with_headers` 用，现在挂在设置页和播放页）。
struct URLEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var uri = ""
    @State private var token = ""
    let onSubmit: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开直连链接").font(.headline)
            TextField("http://…/Videos/{id}/stream?static=true", text: $uri)
                .textFieldStyle(.roundedBorder)
            SecureField("Jellyfin AccessToken（可留空）", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("token 只作为请求头发给内核，不写进 URL、不落日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("播放") {
                    onSubmit(uri.trimmingCharacters(in: .whitespacesAndNewlines),
                             token.isEmpty ? nil : token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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

/// 设置页的「诊断」区：日志路径 / 最近记录（可滚动）/ 清空。
/// 不出「导出文件」按钮——直接在 Finder 里打开日志目录更直观。
struct DiagnosticsSection: View {
    @State private var records: [DiagnosticEntry] = []
    @State private var summaryText = "—"
    @State private var revealPath = false

    var body: some View {
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

        row("记录数 / 大小", summaryText)
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

        Button(role: .destructive) {
            try? AppDiagnostics.logger.clear()
            Task { await refresh() }
        } label: {
            Label("清空日志", systemImage: "trash")
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

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
