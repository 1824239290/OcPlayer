import AppDesignKit
import MoviePilotKit
import SwiftUI

/// 下载管理：5 秒轮询进度，支持开始 / 暂停 / 删除。
/// 离页（视图销毁）自动停轮询；下载完成从列表消失属正常（MoviePilot 转入整理）。
///
/// 页面透明透显整窗氛围底（与 MoviePilot 首页同一张背景图）：macOS 常规布局
/// 靠 AppShell 根节点垫的首页轮播，页面不画任何底；iOS / 紧凑布局整窗层到不了
/// 屏幕，自垫 `app.currentAmbienceTarget`（轮播当前那张，与 MoviePilot Tab 同源）。
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
    /// 前台门控用。见 `.task(id:)` 与 `DownloadsPollingPolicy`。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let notice {
                    MoviePilotNoticeBanner(text: notice, isError: isNoticeError, glassCard: true)
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
        // 氛围背景：走统一入口。本页没有自己的主体图，用会话池那张
        // （与 MoviePilot Tab、首页轮播同源，跨页背景连续、不多拉一次图）。
        // target 为 nil（池子还没装好）时该入口会出兜底纯色，页面不留白底。
        .pageAmbience(AmbienceTarget.sessionPool(app))
        // 5 秒轮询：视图在树上就转，销毁即取消（.task 生命周期）。
        //
        // **`.task(id:)` 而不是普通 `.task`**：`.task` 的闭包捕获的是启动那一刻的
        // 视图快照，循环里读 `scenePhase` 永远读到旧值 —— SwiftUI 的经典坑。
        // 只有把相位放进 id，相位一变才会取消并重建任务。
        .task(id: DownloadsPollingPolicy.taskID(scenePhase)) {
            await DownloadsPollingPolicy.runPollingLoop(phase: scenePhase) {
                await refresh()
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
        EmptyState(
            empty: "没有下载中的任务",
            systemImage: "arrow.down.circle",
            message: "当前没有下载中的任务。下载完成的项目由 MoviePilot 整理后进入 Jellyfin 媒体库。",
            actionTitle: "刷新"
        ) {
            Task { await refresh() }
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
        .liquidGlassCard()
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
        } catch {
            // 取消分两种形态，都要当「不是错误」：
            // ① `CancellationError` —— Swift 结构化并发的取消；
            // ② `MoviePilotError.ignore` —— `URLSession` 抛的 `URLError(.cancelled)`
            //    经 `MoviePilotError(networkError:)` 映射而来，**不是**
            //    `CancellationError`，落不到 ①。只 catch ① 的话，切相位 / 离页取消
            //    会在页面上闪一张「请求已取消」的错误卡片。
            if DownloadsRefreshSurface.shouldSurfaceError(error) {
                loadError = MoviePilotError.userMessage(of: error)
            }
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
                notice = MoviePilotError.userMessage(of: error)
                isNoticeError = true
            }
            actionInFlight.remove(task.id)
            await refresh()
        }
    }
}

// MARK: - 轮询门控

/// 下载页 5 秒轮询的前台判据。
///
/// ## 为什么只认 `.background`
///
/// 本机实测（`REJ-07`）：macOS `⌘H` 隐藏 → **`.background`**；最小化 → `.inactive`。
/// 看起来「最小化也该停」，但 **`.inactive` 同时表示「应用不在最前」** —— 窗口还
/// 完整可见、用户只是点了别的 app，也是 `.inactive`。拿它当「不可见」信号会让
/// **看得见的进度条冻住**，比多几次请求糟得多。
///
/// 所以只停 `.background`（隐藏 / iOS 进后台）。代价是最小化时仍每 5 s 发一次
/// 请求（窗口不可见但进程还在），这是已知的、被接受的残余。
///
/// ## ⚠️ macOS 上 `.inactive` 的来源（实测更正）
///
/// 本批最初的注释写「`.inactive` 同时表示『应用不在最前』，用户点了别的 app 也是
/// `.inactive`」。**独立审查用最小 SwiftUI app 实测推翻了这条**：macOS 26.6 上
/// 切到别的 app（`NSApp.isActive == false` 持续 2 s）**不产生任何相位变化**，
/// `scenePhase` 一直是 `.active`。本机 `.inactive` 主要来自**最小化**，
/// `.background` 来自 `⌘H` 隐藏。
///
/// 结论（只停 `.background`）不变，但**依据要换掉**：iOS 上 `.inactive` 确实是
/// 通知中心 / 切换器 / 来电那一类短暂状态，把它们当「不可见」去停轮询会让重进前台
/// 的首帧空一拍。真正「窗口是否可见」的精确判据是
/// `NSWindow.occlusionState` / `miniaturized`，不是 `scenePhase` —— 于是最小化
/// 仍轮询成了这个方案的**已知残余**，而不是「安全取舍」。
///
/// ## 为什么不是所有轮询都加这个门控
///
/// 全仓 7 个 `while !Task.isCancelled` 循环里，**5 个是播放相关**（
/// `PlaybackReportingCoordinator` 心跳、`PlaybackController` 的 4 个）—— 它们
/// **必须**在后台继续：`UIBackgroundModes: audio` 下后台播放要照常上报进度。
/// 给它们加门控会直接破坏后台播放。氛围轮播（12 s）不产生网络请求、隐藏窗口
/// 不渲染，浪费接近零，改它要动 `.task(id: ambienceTrigger)` 的重启语义，得不偿失。
enum DownloadsPollingPolicy {
    /// 该相位要不要继续轮询。
    ///
    /// 纯函数、`nonisolated`：门控逻辑能单独断言，不必起视图。
    static func shouldPoll(_ phase: ScenePhase) -> Bool {
        phase != .background
    }

    /// 轮询循环本体。抽出来是为了**可断言**：门控只写在视图里的话，
    /// 「`.background` 时到底会不会取数」只能靠起视图手工观察
    /// （独立审查实测：删掉 guard 后隐藏 16 秒仍会 refresh 4 次，
    /// 而纯函数用例一条都不红）。
    ///
    /// - Parameter fetch: 一次取数。生产传入视图的 `refresh()`。
    /// - Parameter interval: 轮询间隔。生产默认 5 s；测试注入极短间隔。
    @MainActor
    static func runPollingLoop(
        phase: ScenePhase,
        interval: Duration = .seconds(5),
        fetch: () async -> Void
    ) async {
        guard shouldPoll(phase) else { return }
        while !Task.isCancelled {
            await fetch()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: interval)
        }
    }

    /// `.task(id:)` 的触发键。**只在「轮询决定」变化时才变**，不是「相位一变就变」。
    ///
    /// ## 为什么不能按相位逐个给 id
    ///
    /// 第一版让 `.active` / `.inactive` / `.background` 各占一个 id。后果是
    /// `.active ↔ .inactive` 每次切换都会**取消并重建**轮询任务 —— 而在飞的那次
    /// `refresh()` 被取消后，`URLSession` 抛的是 `URLError(.cancelled)`（**不是**
    /// `CancellationError`），经 `MoviePilotError(networkError:)` 映射成
    /// `.ignore("请求已取消")`，`refresh()` 的通用 `catch` 就把它写进 `loadError`
    /// —— 用户点一下别的窗口再回来，就看到一条「请求已取消」的错误卡片。
    ///
    /// 而 `.active` 与 `.inactive` 的**轮询决定完全相同**（都要轮），没有任何理由
    /// 为它们重建任务。所以 id 只区分「轮」与「不轮」两种状态：
    /// `.inactive → .active` 不重启，只有进出 `.background` 才重启。
    static func taskID(_ phase: ScenePhase) -> Int {
        shouldPoll(phase) ? 0 : 1
    }
}

/// 刷新失败时**要不要**显示错误卡片。
///
/// 抽成纯函数是为了可断言：取消类错误不该出现在 UI 上，而这条判据藏在
/// `refresh()` 的 catch 链里时只能靠起视图验证。
enum DownloadsRefreshSurface {
    static func shouldSurfaceError(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let moviePilot = error as? MoviePilotError, case .ignore = moviePilot { return false }
        return true
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
                    // 站点名是身份标签、不是强调：中性档（原来钉的是通用蓝，全 App 去蓝后
                    // 它会成为画面上唯一的色相，比状态色还抢眼）。
                    PillChip(site, role: .neutral, font: .caption2.weight(.semibold), bordered: true)
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
        .liquidGlassCard()
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
