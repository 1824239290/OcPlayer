import AppDesignKit
import DanmakuKit
import DiagnosticsKit
import SwiftUI

/// 设置 → 维护：缓存（图片 / 媒体元数据）与日志诊断。
struct MaintenanceSettingsView: View {
    @Environment(AppModel.self) private var app
    /// 弹幕诊断日志开关（默认关闭）：与 PlaybackPreferences.danmakuDiagnosticsEnabled
    /// 同一 key，@AppStorage 双向可观察，改了立即生效。
    @AppStorage(SettingsKeys.danmakuDiagnostics) private var danmakuDiagnosticsEnabled = false

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection("缓存") {
                // 两个嵌套的独立 View（各自多根，卡内自动平铺成多行），内部结构不动。
                ImageCacheSettingsRow()
                SettingsGlassDivider()
                MetadataCacheSettingsRow()
            }

            SettingsGlassSection("配置备份与多端同步") {
                // 嵌套独立 View：多根自动平铺成多行（导出 / 恢复 / 状态提示）。
                ConfigBackupSection()
            } footer: {
                // 不用 `**粗体**`：多个字面量相加得到的是 String，`Text(String)` 不解析
                // markdown，星号会原样画出来。
                Text("把 TMDB Key、播放偏好等设置导出成一个文件，可存进 iCloud 云盘或隔空投送（AirDrop）给其他设备。"
                     + "备份文件里是明文 TMDB Key（不含服务器地址与账号密码），请勿公开分享。")
            }

            SettingsGlassSection("日志与诊断") {
                // 嵌套独立 View：多根自动平铺成多行（详细日志 / 日志文件 / 记录数 /
                // 最近记录 / 导出 / 清空），内部结构不动。
                DiagnosticsSection()
                SettingsGlassDivider()
                Toggle("弹幕诊断日志", isOn: $danmakuDiagnosticsEnabled)
                .neutralSwitch()
                SettingsNote("排查弹幕时间轴错位等问题时再开，平时保持关闭。")
            } footer: {
                Text("日志写入 \(AppDiagnostics.fileURL.path)，含脱敏后的 token / 路径信息；需要完整上下文请导出后发送。")
            }
        }
    }
}

// MARK: - 缓存行

private struct ImageCacheSettingsRow: View {
    @State private var usageText = "—"
    @State private var isClearing = false
    @State private var confirmClear = false

    var body: some View {
        // 2026-10-22：`LabeledContent` 脱离 `Form` 后不再有「标签左 / 值右」的行形态
        // （SwiftUI 只在列表容器里给它那个排版），换成已有的 `KeyValueRow`。
        KeyValueRow(label: "图片缓存", value: usageText)
            .onAppear(perform: refresh)

        Button(role: .destructive) {
            confirmClear = true
        } label: {
            Label("清空图片缓存", systemImage: "trash")
        }
        .disabled(isClearing)
        .confirmationDialog(
            "清空图片缓存？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { clearCache() }
        } message: {
            Text("已缓存的图片会被删除，浏览时重新下载（几秒钟的事）。")
        }
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
        // 目录内**每文件一次 stat** + 全量排序：512 MB 上限下可有数千个小文件，
        // 留在主线程就是进页卡顿（冷目录时几十~几百 ms）。与同页「导出诊断包」
        // 「清空图片缓存」一致，挪到后台算，回主 actor 只赋字符串。
        Task {
            let usage = await Task.detached(priority: .utility) {
                ImagePipeline.shared.diskUsage
            }.value
            usageText = "\(Self.format(usage.usedBytes)) / \(Self.format(usage.capacityBytes))"
        }
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
    @State private var confirmClear = false

    var body: some View {
        // 同 `ImageCacheSettingsRow`：脱离 Form 后 `LabeledContent` 会左贴紧凑排。
        KeyValueRow(label: "媒体元数据缓存", value: usageText)
            .onAppear { app.metadata.refreshSize() }

        HStack {
            Button(role: .destructive) {
                confirmClear = true
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
        .confirmationDialog(
            "清空媒体元数据缓存？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { clear() }
        } message: {
            Text("下次进首页/详情会重新拉取；离线时将无法展示已缓存的内容。")
        }
    }

    /// 数据库体积；未建库（启动早期 / 建库失败）时显示占位而不是 0。
    private var usageText: String {
        if app.metadata.setupError != nil { return "不可用" }
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

// MARK: - 诊断

/// 诊断区：详细日志开关 / 导出诊断包 / 日志路径 / 最近记录（可滚动）/ 清空。
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
    @State private var confirmClearLog = false

    var body: some View {
        Toggle("详细日志", isOn: $verboseLogging)
        .neutralSwitch()
            .onChange(of: verboseLogging) { _, _ in
                // 立即生效：改的是日志管线的进程级最低级别，不需要重启。
                DiagnosticsSettings.apply()
            }

        SettingsNote("打开后记录 debug 级链路细节（守卫拒绝、中间态）并打开内核 trace"
            + "（HTTP 逐请求 / 播放读失败 / HDR 调试，**下一次播放生效**）；"
            + "关闭时只记状态迁移与失败。")

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
                .settingsCardCompact()
        }

        Button(role: .destructive) {
            confirmClearLog = true
        } label: {
            Label("清空日志", systemImage: "trash")
        }
        .confirmationDialog(
            "清空日志？",
            isPresented: $confirmClearLog,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                try? AppDiagnostics.logger.clear()
                Task { await refresh() }
            }
        } message: {
            Text("如需反馈问题请先导出诊断包；清空后不可恢复。")
        }
    }

    /// 导出内容要读整份日志（可能几 MB），挪出主线程再回来开面板（同 refresh 的做法）。
    private func export() {
        Task {
            // `makeText` 产字符串、`Data(text.utf8)` 是一次整份编码 —— 两者都在
            // detached 上做完，主线程只负责开面板。改前那次编码在 `fileWrapper` 里
            // （SwiftUI 主线程调用），导出瞬间会多一次主线程大块分配。
            let result: (data: Data?, failure: String?) = await Task.detached {
                do {
                    let text = try DiagnosticsExport.makeText()
                    return (Data(text.utf8), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            if let data = result.data {
                exportDocument = DiagnosticExportDocument(data: data)
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

// MARK: - 配置备份与多端同步

private struct ConfigBackupSection: View {
    @Environment(AppModel.self) private var app

    @State private var isExporting = false
    @State private var exportDocument: ConfigBackupDocument?
    @State private var isImporting = false

    @State private var pendingBackup: AppConfigBackup?
    @State private var pendingSummary: BackupSummary?
    @State private var showImportConfirmation = false

    @State private var statusNotice: String?
    @State private var isError = false

    var body: some View {
        Button {
            exportConfig()
        } label: {
            Label("导出配置文件…", systemImage: "square.and.arrow.up")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: ConfigBackupCoordinator.suggestedFileName()
        ) { result in
            switch result {
            case .success:
                statusNotice = "配置已成功导出"
                isError = false
            case .failure(let error):
                statusNotice = "导出失败：\(error.localizedDescription)"
                isError = true
            }
        }

        Button {
            isImporting = true
        } label: {
            Label("从文件恢复配置…", systemImage: "square.and.arrow.down")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .confirmationDialog(
            "确认恢复配置？",
            isPresented: $showImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("覆盖恢复") {
                applyPendingBackup()
            }
            Button("取消", role: .cancel) {
                pendingBackup = nil
                pendingSummary = nil
            }
        } message: {
            if let summary = pendingSummary {
                Text(confirmationMessage(for: summary))
            } else {
                Text("将使用该文件覆盖当前的播放偏好与 TMDB Key。")
            }
        }

        if let statusNotice {
            Text(statusNotice)
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .settingsCardCompact()
        }
    }

    /// 弹幕设置经 `AppModel` 取（同一个实例），不再单独 `@Environment(...)`：
    /// 少一层环境依赖，也保证写回的是播放链路正在用的那一份。
    private var dandanplayStore: DandanplaySettingsStore {
        app.danmakuModel.dandanplayStore
    }

    private func exportConfig() {
        let backup = ConfigBackupCoordinator.makeBackup(
            tmdb: app.tmdb,
            // 传**原始值**：未自定义时是 nil，不该把内置默认网关写进备份文件。
            dandanplayGatewayURL: dandanplayStore.gatewayURLString
        )
        do {
            exportDocument = try ConfigBackupDocument(backup: backup)
            isExporting = true
            statusNotice = nil
        } catch {
            statusNotice = "生成备份失败：\(error.localizedDescription)"
            isError = true
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // app 关闭沙盒授权后 URL 立刻失效，所以读盘要在这里就发起。
            Task {
                do {
                    let backup = try ConfigBackupCoordinator.readBackup(from: url)
                    pendingBackup = backup
                    pendingSummary = ConfigBackupCoordinator.summary(of: backup)
                    showImportConfirmation = true
                    statusNotice = nil
                } catch {
                    statusNotice = "读取失败：\(error.localizedDescription)"
                    isError = true
                }
            }
        case .failure(let error):
            statusNotice = "选取文件失败：\(error.localizedDescription)"
            isError = true
        }
    }

    private func applyPendingBackup() {
        guard let backup = pendingBackup else { return }
        ConfigBackupCoordinator.applyBackup(
            backup,
            tmdb: app.tmdb,
            dandanplayStore: dandanplayStore
        )
        pendingBackup = nil
        pendingSummary = nil
        statusNotice = "配置已成功恢复并生效"
        isError = false
    }

    private func confirmationMessage(for summary: BackupSummary) -> String {
        var items: [String] = []
        if summary.hasTMDb {
            let tail = summary.tmdbKeyTail ?? ""
            let lang = summary.tmdbLanguage ?? "zh-CN"
            items.append("• TMDB Key: \(tail)（语言: \(lang)）")
        }
        if summary.hasPlayback {
            items.append("• 播放器与字幕偏好")
        }
        if summary.hasDanmaku {
            items.append("• 弹幕偏好")
        }
        if summary.hasGeneral {
            items.append("• 常规偏好")
        }
        let fromDevice = summary.deviceName.map { "（来自 \($0)）" } ?? ""
        return "导出时间: \(summary.exportedAtFormatted)\(fromDevice)\n\n包含内容:\n"
            + items.joined(separator: "\n")
            + "\n\n点击「覆盖恢复」将更新当前设置。"
    }
}
