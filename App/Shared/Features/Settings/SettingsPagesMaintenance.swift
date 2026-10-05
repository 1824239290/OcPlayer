import AppDesignKit
import DiagnosticsKit
import SwiftUI

/// 设置 → 维护：缓存（图片 / 媒体元数据）与日志诊断。
struct MaintenanceSettingsView: View {
    @Environment(AppModel.self) private var app
    /// 弹幕诊断日志开关（默认关闭）：与 PlaybackPreferences.danmakuDiagnosticsEnabled
    /// 同一 key，@AppStorage 双向可观察，改了立即生效。
    @AppStorage(SettingsKeys.danmakuDiagnostics) private var danmakuDiagnosticsEnabled = false

    var body: some View {
        Form {
            Section("缓存") {
                ImageCacheSettingsRow()
                MetadataCacheSettingsRow()
            }
            .settingsRowBackground()

            Section {
                DiagnosticsSection()
                Toggle("弹幕诊断日志", isOn: $danmakuDiagnosticsEnabled)
                Text("排查弹幕时间轴错位等问题时再开，平时保持关闭。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("日志与诊断")
            } footer: {
                Text("日志写入 \(AppDiagnostics.fileURL.path)，含脱敏后的 token / 路径信息；需要完整上下文请导出后发送。")
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}

// MARK: - 缓存行

private struct ImageCacheSettingsRow: View {
    @State private var usageText = "—"
    @State private var isClearing = false
    @State private var confirmClear = false

    var body: some View {
        LabeledContent("图片缓存", value: usageText)
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
    @State private var confirmClear = false

    var body: some View {
        LabeledContent("媒体元数据缓存", value: usageText)
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
