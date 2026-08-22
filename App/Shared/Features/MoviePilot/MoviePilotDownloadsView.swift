import MoviePilotKit
import SwiftUI

/// 下载管理：5 秒轮询进度，支持开始 / 暂停 / 删除。
/// 离页（视图销毁）自动停轮询；下载完成从列表消失属正常（MoviePilot 转入整理）。
struct MoviePilotDownloadsView: View {
    @Environment(AppModel.self) private var app

    @State private var tasks: [MPDownloadTask] = []
    @State private var loadError: String?
    @State private var actionInFlight: Set<String> = []
    @State private var pendingDelete: MPDownloadTask?
    @State private var notice: String?
    @State private var isNoticeError = false
    @State private var isFirstLoad = true

    var body: some View {
        List {
            if let notice {
                Section {
                    Label(notice, systemImage: isNoticeError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isNoticeError ? .red : .green)
                        .font(.callout)
                }
            }

            Section {
                if isFirstLoad {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在加载…").foregroundStyle(.secondary)
                    }
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red).font(.callout)
                    Button("重试") { isFirstLoad = true }
                } else if tasks.isEmpty {
                    Text("当前没有下载中的任务。下载完成的项目由 MoviePilot 整理后进入 Jellyfin 媒体库。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tasks) { task in
                        row(task)
                    }
                }
            } header: {
                if !tasks.isEmpty { Text("下载中 \(tasks.count)") }
            }
        }
        .navigationTitle("下载管理")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // 5 秒轮询：视图在树上就转，销毁即取消（.task 生命周期）。
            while !Task.isCancelled {
                await refresh()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .refreshable { await refresh() }
        .confirmationDialog(
            "删除下载任务？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { task in
            Button("删除「\(task.name ?? task.title ?? "任务")」", role: .destructive) {
                run(task) { try await MoviePilotAPIClient.shared.removeDownload(hash: task.id) }
            }
        } message: { _ in
            Text("只删下载器里的任务，已下载的文件不会被删。")
        }
    }

    // MARK: - 行

    private func row(_ task: MPDownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name ?? task.title ?? "未命名任务")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let site = task.siteName { Text(site) }
                        Text(task.sizeText)
                        if let state = task.state { Text(state) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    if task.isPaused {
                        Button {
                            run(task) { try await MoviePilotAPIClient.shared.startDownload(hash: task.id) }
                        } label: {
                            Label("开始", systemImage: "play.fill")
                        }
                    } else {
                        Button {
                            run(task) { try await MoviePilotAPIClient.shared.stopDownload(hash: task.id) }
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = task
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    if actionInFlight.contains(task.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(actionInFlight.contains(task.id))
            }

            ProgressView(value: task.progressFraction)
                .progressViewStyle(.linear)
            HStack(spacing: 8) {
                Text("\(Int((task.progressFraction * 100).rounded()))%")
                if let dlspeed = task.dlspeed, !dlspeed.isEmpty, !task.isPaused {
                    Text(dlspeed)
                }
                if let left = task.leftTime, !left.isEmpty {
                    Text("剩余 \(left)")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数据

    private func refresh() async {
        do {
            let fetched = try await MoviePilotAPIClient.shared.downloadingTasks()
            tasks = fetched
            loadError = nil
        } catch is CancellationError {
            // 离页取消，不算错误
        } catch {
            loadError = (error as? MoviePilotError)?.userMessage ?? "\(error)"
        }
        isFirstLoad = false
    }

    private func run(_ task: MPDownloadTask, _ operation: @escaping () async throws -> Void) {
        actionInFlight.insert(task.id)
        notice = nil
        Task {
            do {
                try await operation()
            } catch {
                notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
                isNoticeError = true
            }
            actionInFlight.remove(task.id)
            await refresh()
        }
    }
}
