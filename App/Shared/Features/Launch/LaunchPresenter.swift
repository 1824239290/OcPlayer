import AppDesignKit
import DiagnosticsKit
import Observation
import SwiftUI

/// 启动体验的状态机：**要不要播**（门控）、**何时交棒**（时钟）、**何时撤除**。
///
/// 门控（全部满足才播，其余情况一律安静跳过并记诊断）：
/// * **进程内只播一次**——`RootView` 在 macOS 关窗重开时会被重建，回前台不重建但
///   也绝不重播；进程级标记是唯一可靠的防重播点。
/// * **测试宿主不播**（`RuntimeEnvironment.isRunningTests`，与 bootstrap 的守卫同源）。
/// * **自动化通道不播**（`OCPLAYER_SELFTEST` 下的 `START_SECTION` / `START_ROUTE` /
///   `SELFTEST_FILE`，及显式 `OCPLAYER_LAUNCH_ANIMATION=0`）——验收台的逐页截图
///   不能第一秒拍在标志上，这是本功能最大的回归风险。
/// * **减弱动态**：改播静态标志（无描边/呼吸/脉冲，下限降到 600ms，见 `LaunchTimeline`）。
///
/// 时钟：`startDate` 是时间轴零点（`begin` 那一刻，早于首帧渲染，保证 0–80ms 的
/// 「底色先行」真实存在）；`contentBecameReady()` 由 `RootView` 在 phase 离开
/// `.boot` 时调用，退场任务据此调度。bootstrap 未就绪就**永远呼吸等待**——
/// 退场只由数据就绪驱动，不看时间上限（3.5s 未就绪会记一条诊断）。
///
/// 可测性：时间轴零点经 `beginForTesting(at:)` 注入、三个就绪信号都带 `now:`
/// 注入（默认 `.now`），`LaunchPresenterTests` 用固定日期钉状态机，不靠真等。
@MainActor
@Observable
final class LaunchPresenter {
    private(set) var isVisible = false
    private(set) var reduceMotion = false
    /// 内容就绪时刻（相对 `startDate` 的毫秒）；nil = 仍在等。
    private(set) var readyAtMs: Double?
    /// 氛围池就绪时刻（同口径）；nil = 还在等（或没有会话/不预期有氛围图）。
    private(set) var ambienceReadyAtMs: Double?
    /// 首页内容就绪时刻（骨架期结束 / 有内容可看）；nil = 还在等或不等。
    private(set) var homeReadyAtMs: Double?
    /// 有会话、预期首页会有氛围图 → 交棒前等池子就绪（上限 `ambienceHoldCap`）。
    private(set) var holdForAmbience = false
    /// 有会话 → 交棒前等首页脱离骨架期（同一个上限，不叠加）。
    private(set) var holdForHome = false
    /// Debug 冻结旋钮（`OCPLAYER_LAUNCH_FREEZE_MS`）：时间轴钉死在该时刻，
    /// 自动化逐帧截图用；冻结态永不自动撤除。生产恒 nil。
    private(set) var frozenMs: Double?
    private(set) var started = false
    private(set) var startDate = Date.now

    private var pendingReady = false
    private var pendingExpectAmbience = false
    private var pendingExpectHome = false
    /// 氛围池就绪信号早于 `contentBecameReady`（hold 标志还没立起来）时先存着，
    /// 等内容就绪那一刻补上——否则这次 onChange 消费掉就再也没有下一次，
    /// hold 会白等到上限、交棒后首页才补背景。
    private var pendingAmbienceReady = false
    /// 首页就绪信号同理（缓存命中时可能比 phase 翻转还快）。
    private var pendingHomeReady = false
    /// 交棒开始（启动层开始整体淡出）时回调一次。macOS 覆盖窗口用它做兜底淡出；
    /// iOS 不用。
    var onExitStart: (() -> Void)?
    /// 退场时刻排定（`scheduleDismiss` 每次重排都回调，带时间轴零点）。macOS 覆盖
    /// 窗口据此**预提交** CA 淡出动画（`beginTime` 指向未来）：deadline 前后主线程
    /// 正被首页装配堵死时，排定时刻的淡出由渲染服务器准点执行，不再顺延
    /// （实测主线程拥堵把交棒推迟了 ~2.4s）。
    var onExitScheduled: ((_ exitStartMs: Double, _ timelineStart: Date) -> Void)?
    /// 已排定的退场开始时刻（毫秒口径）；每次重排更新。`present` 晚于首次排定时
    /// （pendingReady 回放路径），覆盖窗口靠它补一次预提交。
    private(set) var scheduledExitStartMs: Double?
    /// `OCPLAYER_LAUNCH_READY_MS`（Debug 截图旋钮）：钉死数据就绪时刻。
    private(set) var readyOverrideMs: Double?
    private var idleWatchdog: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    /// 已调度的退场截止（毫秒口径）； ambience 只会把它提前，重入时用来去重。
    private var dismissDeadlineMs: Double?
    /// 进程级「已播」标记：`RootView` 重建（macOS 关窗重开）也不重播。
    private static var hasPlayedThisProcess = false

    private let timeline = LaunchTimeline()

    /// 时间轴当前时刻（毫秒）。冻结旋钮优先。
    func elapsed(at date: Date) -> Double {
        if let frozenMs { return frozenMs }
        return max(0, date.timeIntervalSince(startDate) * 1000)
    }

    /// `RootView` 出现（或从后台激活）时调用：过门控、起时间轴。
    func begin(reduceMotion: Bool) {
        guard !started else { return }
        started = true
        self.reduceMotion = reduceMotion
        #if OCPLAYER_SELFTEST
        if LaunchOptions.suppressesLaunchAnimation {
            logSkipped("自动化通道")
            return
        }
        frozenMs = LaunchOptions.launchFreezeMs
        readyOverrideMs = LaunchOptions.launchReadyMs
        #endif
        if RuntimeEnvironment.isRunningTests {
            logSkipped("测试宿主")
            return
        }
        if Self.hasPlayedThisProcess {
            logSkipped("本进程已播")
            return
        }
        Self.hasPlayedThisProcess = true
        startTimeline(at: .now)
    }

    /// 时间轴起表（`begin` 门控通过后与测试入口 `beginForTesting` 共用）：
    /// 起零点、补放早到信号、起呼吸等待看门狗。
    private func startTimeline(at date: Date) {
        startDate = date
        isVisible = true
        AppDiagnostics.logInfo("启动动画开始", fields: [
            "reduceMotion": .boolean(reduceMotion),
            "frozen": .boolean(frozenMs != nil),
        ])
        // begin 之前 phase 就翻了（onAppear 与 .task 的竞态兜底）。
        if pendingReady {
            contentBecameReady(
                expectAmbience: pendingExpectAmbience,
                expectHome: pendingExpectHome,
                now: date)
            return
        }
        // 呼吸等待是设计，但等待时长要能从诊断里看出来。
        idleWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(3500))
            guard let self, self.isVisible, self.readyAtMs == nil else { return }
            AppDiagnostics.logWarning("启动动画等待数据超时", fields: ["waitedMs": .integer(3500)])
        }
    }

    /// 启动数据就绪（phase 离开 `.boot`）：记时刻、调度退场。只生效一次。
    /// - Parameters:
    ///   - expectAmbience: 有会话（预期首页有氛围图）→ 交棒前等氛围池就绪。
    ///   - expectHome: 有会话（落在首页）→ 交棒前等首页脱离骨架期。
    ///   - now: 信号到达时刻（注入点；生产走默认 `.now`）。
    ///   两个门控共享 `ambienceHoldCap` 上限；onboarding / 本地播放都不等。
    func contentBecameReady(expectAmbience: Bool, expectHome: Bool = false, now: Date = .now) {
        guard started else {
            pendingReady = true
            pendingExpectAmbience = expectAmbience
            pendingExpectHome = expectHome
            return
        }
        guard isVisible, readyAtMs == nil else { return }
        idleWatchdog?.cancel()
        holdForAmbience = expectAmbience
        holdForHome = expectHome
        let nowMs = max(0, now.timeIntervalSince(startDate) * 1000)
        // 信号比内容就绪先到的（缓存命中）：补记就绪时刻。
        if expectAmbience && pendingAmbienceReady {
            pendingAmbienceReady = false
            ambienceReadyAtMs = nowMs
        }
        if expectHome && pendingHomeReady {
            pendingHomeReady = false
            homeReadyAtMs = nowMs
        }
        if let readyOverride = readyOverrideMs {
            // 截图旋钮：把「数据就绪」钉在指定时刻（与时间轴冻结配合，能拍到
            // 呼吸等待态——真实机器的 bootstrap 太快，抓不到这一段）。
            readyAtMs = readyOverride
        } else {
            readyAtMs = nowMs
        }
        scheduleDismiss()
    }

    /// 氛围池就绪（池子非空 = 首图已预热）：把退场提前到「就绪 + 一拍」。
    /// **迟到不回卷**——若此刻已过当前退场起点（氛围等超时、交棒已开始），
    /// 忽略本次信号，维持按上限的退场。
    func ambienceBecameReady(now: Date = .now) {
        // hold 标志还没立起来（内容未就绪/还没 begin）就先存信号，等
        // contentBecameReady 来补——这个信号只有 onChange 这一次，丢了就全等上限。
        guard holdForAmbience else {
            pendingAmbienceReady = true
            return
        }
        guard started, isVisible, ambienceReadyAtMs == nil else { return }
        let nowMs = max(0, now.timeIntervalSince(startDate) * 1000)
        guard let pendingStart = timeline.exitStart(
            readyAt: readyAtMs,
            ambienceReadyAt: nil,
            homeReadyAt: homeReadyAtMs,
            holdForAmbience: true,
            holdForHome: holdForHome,
            reduceMotion: reduceMotion),
            nowMs < pendingStart else { return }
        ambienceReadyAtMs = nowMs
        scheduleDismiss()
    }

    /// 首页脱离骨架期（有内容可看 / 空库空态 / 错误态）：与氛围池同一套
    /// 「迟到不回卷、早到先存后补」的门控语义。
    func homeBecameReady(now: Date = .now) {
        guard holdForHome else {
            pendingHomeReady = true
            return
        }
        guard started, isVisible, homeReadyAtMs == nil else { return }
        let nowMs = max(0, now.timeIntervalSince(startDate) * 1000)
        guard let pendingStart = timeline.exitStart(
            readyAt: readyAtMs,
            ambienceReadyAt: ambienceReadyAtMs,
            homeReadyAt: nil,
            holdForAmbience: holdForAmbience,
            holdForHome: true,
            reduceMotion: reduceMotion),
            nowMs < pendingStart else { return }
        homeReadyAtMs = nowMs
        scheduleDismiss()
    }

    /// 按当前状态推退场时刻并调度。已有更早的调度则不动（ambience 只会把退场
    /// 从「上限」提前，不会推迟——提前之外的变化都被上游钳住）。
    private func scheduleDismiss() {
        guard isVisible, readyAtMs != nil, frozenMs == nil else { return }
        guard let exitStart = timeline.exitStart(
            readyAt: readyAtMs,
            ambienceReadyAt: ambienceReadyAtMs,
            homeReadyAt: homeReadyAtMs,
            holdForAmbience: holdForAmbience,
            holdForHome: holdForHome,
            reduceMotion: reduceMotion) else { return }
        let deadline = exitStart + LaunchTimeline.exitDuration
        if let scheduled = dismissDeadlineMs, scheduled <= deadline { return }
        dismissDeadlineMs = deadline
        scheduledExitStartMs = exitStart
        dismissTask?.cancel()
        onExitScheduled?(exitStart, startDate)
        // 排定发生在信号到达时刻，时间轴已经走过一段：退场时刻是时间轴**绝对**
        // 时刻，睡之前必须减掉已走过的量——直接睡 exitStart 会把信号时刻叠加
        // 进去，收尾（撤除 overlay/覆盖窗口、记「启动动画结束」）整体迟到
        // readyAt 那么多（慢 bootstrap 时数秒）。
        let elapsedAtScheduleMs = max(0, Date.now.timeIntervalSince(startDate) * 1000)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(
                for: .milliseconds(Int(max(0, exitStart - elapsedAtScheduleMs).rounded(.up))))
            guard let self, !Task.isCancelled, self.dismissDeadlineMs == deadline else { return }
            // 交棒开始：先给覆盖窗口一次「撤掉底色兜底」的机会，再等淡出走完。
            self.onExitStart?()
            try? await Task.sleep(for: .milliseconds(Int((deadline - exitStart).rounded(.up))))
            guard !Task.isCancelled, self.dismissDeadlineMs == deadline else { return }
            self.isVisible = false
            // 字段逐个装再合字典：大字典字面量会让类型检查器超时
            // （与 bootstrap 的「冷启动分段」同款坑，见 AppModel+Session）。
            var fields: [String: DiagnosticValue] = [:]
            // 实测墙钟时长（时间轴收官 + 任务抖动），不是排定值——排定值会掩盖
            // 调度本身的延迟，这条日志就是用来复诊延迟的。
            fields["durationMs"] = .integer(Int64(max(0, Date.now.timeIntervalSince(self.startDate) * 1000)))
            fields["readyMs"] = self.readyAtMs.map { .integer(Int64($0)) } ?? .string("未就绪")
            fields["ambienceMs"] = self.ambienceReadyAtMs.map { .integer(Int64($0)) } ?? .string(self.holdForAmbience ? "超时未就绪" : "无会话")
            fields["homeMs"] = self.homeReadyAtMs.map { .integer(Int64($0)) } ?? .string(self.holdForHome ? "超时未就绪" : "不等首页")
            fields["reduceMotion"] = .boolean(self.reduceMotion)
            AppDiagnostics.logInfo("启动动画结束", fields: fields)
        }
    }

    /// 减弱动态在启动中途被切换（罕见）：已调度的退场按旧值走，可接受；
    /// `begin` 之后的首次变化仅影响呼吸/静态判定的后续帧。
    func updateReduceMotion(_ value: Bool) {
        guard started else { return }
        reduceMotion = value
    }

    private func logSkipped(_ reason: String) {
        AppDiagnostics.logInfo("启动动画跳过", fields: ["reason": .string(reason)])
    }
}

// MARK: - 测试支撑（仅 Debug 构建，生产路径勿用）

#if DEBUG
extension LaunchPresenter {
    /// 重置进程级「已播」标记。只有 `LaunchPresenterTests` 在 setUp 里调：
    /// 静态标记跨用例存活，不重置的话第一个播放用例之后其余用例全走「已播」跳过。
    static func resetPlaybackGateForTesting() {
        hasPlayedThisProcess = false
    }

    /// 绕过「测试宿主 / 进程已播」门控直起时间轴。门控读的是进程级环境
    /// （XCTest 宿主、静态标记），单元测试无法也不应伪造；生产一律走
    /// `begin(reduceMotion:)`。`at` 注入时间轴零点，配合各信号方法的 `now:`
    /// 参数即可用固定日期钉状态机。
    func beginForTesting(reduceMotion: Bool = false, at date: Date = .now) {
        guard !started else { return }
        started = true
        self.reduceMotion = reduceMotion
        startTimeline(at: date)
    }
}
#endif
