import AppDesignKit
import MoviePilotKit
import SwiftUI

/// 下载管理：5 秒轮询进度，支持开始 / 暂停 / 删除。
/// 离页（视图销毁）自动停轮询；下载完成从列表消失属正常（MoviePilot 转入整理）。
///
/// 页面透明透显整窗氛围底（与 MoviePilot 首页同一张背景图）：macOS 常规布局
/// 靠 AppShell 根节点垫的首页轮播，页面不画任何底；iOS / 紧凑布局整窗层到不了
/// 屏幕，自垫 `app.homeAmbience`（轮播当前那张，与 MoviePilot Tab 同源）。
/// 不走系统 List——它的实底会把氛围层挡死；卡片流与资源搜索页同一套玻璃语言。
struct MoviePilotDownloadsView: View {
    @Environment(AppModel.self) private var app

    @State private var tasks: [MPDownloadTask] = []
    @State private var loadError: String?
    @State private var actionInFlight: Set<String> = []
    @State private var pendingDelete: MPDownloadTask?
    @State private var notice: String?
    @State private var isNoticeError = false
    @State private var isFirstLoad = true

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 页面是否自己垫氛围层：iOS 上整窗层到不了屏幕（见
    /// `WindowAmbience.reachesScreen`），常规布局也得自垫；macOS 常规布局
    /// 保持全透明，透显整窗层。
    private var drawsOwnAmbience: Bool {
        !WindowAmbience.reachesScreen || sizeClass == .compact
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let notice {
                    noticeBanner(notice, isError: isNoticeError)
                }

                if isFirstLoad {
                    loadingState
                } else if let loadError {
                    // 轮询失败不再清掉旧数据：错误卡片置顶，已有任务继续可见。
                    errorCard(loadError)
                    if !tasks.isEmpty {
                        taskList
                    }
                } else if tasks.isEmpty {
                    emptyState
                } else {
                    taskList
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await refresh() }
        .navigationTitle("下载管理")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background {
            if drawsOwnAmbience {
                if let ambience = app.homeAmbience {
                    BackdropAmbienceView(
                        target: (url: ambience.url, authHeader: ambience.authHeader),
                        scrim: ambience.scrim
                    )
                } else {
                    Color.pageBackground.ignoresSafeArea()
                }
            }
        }
        .task {
            // 5 秒轮询：视图在树上就转，销毁即取消（.task 生命周期）。
            while !Task.isCancelled {
                await refresh()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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

    // MARK: - 状态块

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在加载…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有下载中的任务", systemImage: "arrow.down.circle")
        } description: {
            Text("当前没有下载中的任务。下载完成的项目由 MoviePilot 整理后进入 Jellyfin 媒体库。")
        } actions: {
            Button("刷新") { Task { await refresh() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    // MARK: - 任务列表

    @ViewBuilder
    private var taskList: some View {
        HStack(spacing: 8) {
            Text("下载队列")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text("\(tasks.count)")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.quaternary, in: Capsule())
            Spacer()
            Text("每 5 秒自动刷新")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)

        ForEach(tasks) { task in
            DownloadTaskCard(
                task: task,
                isBusy: actionInFlight.contains(task.id),
                onTogglePause: { togglePause(task) },
                onDelete: { pendingDelete = task }
            )
        }
    }

    private func noticeBanner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(isError ? .red : .green)
        .padding(12)
        .liquidGlassCard(cornerRadius: 14)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
            Spacer()
            Button(UIStrings.retry) { isFirstLoad = true }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 16)
    }

    // MARK: - 动作

    private func togglePause(_ task: MPDownloadTask) {
        run(task) {
            if task.isPaused {
                try await MoviePilotAPIClient.shared.startDownload(hash: task.id)
            } else {
                try await MoviePilotAPIClient.shared.stopDownload(hash: task.id)
            }
        }
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

// MARK: - 任务卡片

/// 单个下载任务的液态玻璃卡片：标题 + 状态/站点/体积徽章 + 进度细轨 + 速度行，
/// 右上角开始/暂停与删除两颗玻璃圆钮（删除仍走确认弹窗）。
private struct DownloadTaskCard: View {
    let task: MPDownloadTask
    let isBusy: Bool
    let onTogglePause: () -> Void
    let onDelete: () -> Void

    private var title: String { task.name ?? task.title ?? "未命名任务" }

    /// <10% 保留一位小数，早期进度不至于永远显示 0%。
    private var percentText: String {
        let pct = task.progressFraction * 100
        return pct < 10 ? String(format: "%.1f%%", pct) : "\(Int(pct.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let mediaTitle = task.mediaTitle, mediaTitle != title {
                        Text(mediaTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                actions
            }

            HStack(spacing: 6) {
                if task.isPaused {
                    PillChip("已暂停", role: .custom(.orange), font: .caption2.weight(.semibold))
                } else {
                    PillChip("下载中", role: .custom(.green), font: .caption2.weight(.semibold))
                }
                if let site = task.siteName, !site.isEmpty {
                    PillChip(site, role: .custom(.blue), font: .caption2.weight(.semibold), bordered: true)
                }
                PillChip(task.sizeText, font: .caption2.monospacedDigit())
                Spacer(minLength: 0)
            }

            CardProgressTrack(fraction: task.progressFraction, tint: .accentColor)

            HStack(spacing: 10) {
                Text(percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if !task.isPaused && task.progressFraction < 0.999 {
                    // 已下完的任务还挂在下载器里时，服务端会给 "0 B/s" /
                    // "00:00:00" 这类噪音，一并藏掉。
                    if let dlspeed = task.dlspeed, !dlspeed.isEmpty {
                        Text(dlspeed)
                    }
                    if let left = task.leftTime, !left.isEmpty {
                        Text("剩余 \(left)")
                    }
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 16)
    }

    @ViewBuilder
    private var actions: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        } else {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onTogglePause) {
                        Image(systemName: task.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCapsule(tint: Color.accentColor.opacity(0.15))
                    .help(task.isPaused ? "开始下载" : "暂停下载")
                    .accessibilityLabel(task.isPaused ? "开始下载" : "暂停下载")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCapsule(tint: Color.red.opacity(0.12))
                    .help("删除任务")
                    .accessibilityLabel("删除任务")
                }
            }
        }
    }
}
