import MoviePilotKit
import SwiftUI
import XCTest

@testable import OcPlayer

/// 下载页 5 秒轮询的**前台门控**（性能审查清单 `P2-40`）。
///
/// ## 为什么要单独钉
///
/// 门控写错的两种方式都**看不出来**：
/// - 太松（只判 `Task.isCancelled`）：`⌘H` 隐藏后仍每 5 s 发一次请求，挂机
///   720 次/小时的无用请求，用户完全无感；
/// - 太紧（把 `.inactive` 也停掉）：**看得见的进度条会冻住** —— 因为 `.inactive`
///   同时表示「应用不在最前」，用户点了别的 app 窗口还开着就落到这个相位。
///
/// 所以判据必须是「只停 `.background`」，两条边界都要钉住。
final class DownloadsPollingPolicyTests: XCTestCase {

    /// `.active`：正常前台，必须轮询。
    func testActivePolls() {
        XCTAssertTrue(DownloadsPollingPolicy.shouldPoll(.active))
    }

    /// `.inactive`：**仍然轮询**。这是本策略最容易被改错的一条 ——
    /// macOS 上「窗口最小化」「用户点了别的 app」都落在这里，但窗口内容仍然可见，
    /// 停掉会让用户盯着一个不动的进度条。
    func testInactiveStillPollsBecauseWindowMayBeVisible() {
        XCTAssertTrue(
            DownloadsPollingPolicy.shouldPoll(.inactive),
            "`.inactive` 不等于不可见：它同时表示「应用不在最前」，此时窗口还开着。"
                + "停掉会让看得见的进度条冻住。")
    }

    /// `.background`：隐藏（macOS `⌘H`）/ iOS 进后台，必须停。
    func testBackgroundStopsPolling() {
        XCTAssertFalse(
            DownloadsPollingPolicy.shouldPoll(.background),
            "`.background` 时进程还在跑但界面不可见，继续每 5 s 发请求纯属浪费。")
    }

    /// **`.active` 与 `.inactive` 必须共用同一个 `.task(id:)` 键。**
    ///
    /// 这条是修一个真实缺陷后加的：第一版按相位逐个给 id，于是
    /// `.active ↔ .inactive` 每次切换都取消并重建轮询任务。而在飞的 `refresh()`
    /// 被取消后，`URLSession` 抛 `URLError(.cancelled)`（**不是**
    /// `CancellationError`）→ `MoviePilotError.ignore("请求已取消")` →
    /// `refresh()` 的通用 `catch` 写进 `loadError` → 用户点一下别的窗口再回来
    /// 就看见「请求已取消」错误卡片。
    ///
    /// 两者的轮询决定本来就一样，没有任何理由为它们重建任务。
    func testTaskIDIsStableAcrossActiveAndInactive() {
        XCTAssertEqual(
            DownloadsPollingPolicy.taskID(.active),
            DownloadsPollingPolicy.taskID(.inactive),
            "`.active` 与 `.inactive` 都要轮询，共用一个键才不会每次切相位都取消重建任务")
    }

    /// 进出 `.background` 必须换键 —— 否则任务不会重启，回到前台也不恢复轮询。
    func testTaskIDChangesWhenPollingDecisionChanges() {
        let polling = DownloadsPollingPolicy.taskID(.active)
        let stopped = DownloadsPollingPolicy.taskID(.background)
        XCTAssertNotEqual(polling, stopped, "轮询决定变了就必须换键，否则任务不会重启/停止")
    }

    // MARK: 接线（不只是纯函数）

    /// **`.background` 时循环一次都不取数。**
    ///
    /// 这条是审查指出的测试缺口：只断言 `shouldPoll` 的返回值时，把视图里的
    /// `guard shouldPoll(...)` 删掉（或把 `.task(id:)` 改回普通 `.task`），
    /// 纯函数用例一条都不红 —— 审查实测删掉 guard 后，隐藏 16 秒仍 refresh 4 次。
    ///
    /// 所以把循环本体提成 `runPollingLoop(phase:interval:fetch:)`，这里直接驱动它。
    func testBackgroundLoopNeverFetches() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        await DownloadsPollingPolicy.runPollingLoop(phase: .background) {
            counter.bump()
        }
        XCTAssertEqual(counter.count, 0, "`.background` 时一次都不该取数")
    }

    /// **`.inactive` 时循环真的会转**（且能被取消停下来）。
    ///
    /// 用 1 ms 间隔跑 60 ms：至少取数一次；再验证取消后不再继续。
    func testInactiveLoopFetchesAndStopsOnCancel() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        let task = Task {
            await DownloadsPollingPolicy.runPollingLoop(
                phase: .inactive, interval: .milliseconds(1)
            ) {
                counter.bump()
            }
        }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value
        let afterCancel = counter.count
        XCTAssertGreaterThan(afterCancel, 0, "`.inactive` 仍要轮询（窗口可能可见）")

        // 取消后必须真的停：再等一会儿，计数不应继续涨。
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(counter.count, afterCancel, "取消后循环必须停下")
    }

    /// 键只有两种取值，与「轮 / 不轮」一一对应（改动会被这条钉住）。
    func testTaskIDValuesAreStable() {
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.active), 0)
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.inactive), 0)
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.background), 1)
    }
}

/// 刷新失败时**要不要**显示错误卡片。
///
/// 这条独立成文件里的一个小块，是因为它守着一条真实会发生的坏体验：切相位 /
/// 离页取消时，`URLSession` 抛的是 `URLError(.cancelled)`（不是
/// `CancellationError`），经 `MoviePilotError(networkError:)` 映射成
/// `.ignore("请求已取消")`。只 catch `CancellationError` 的话，用户点一下别的窗口
/// 再回来就会看到一张「请求已取消」的错误卡片。
final class DownloadsRefreshSurfaceTests: XCTestCase {

    /// `CancellationError` 不显示。
    func testCancellationErrorIsSilent() {
        XCTAssertFalse(DownloadsRefreshSurface.shouldSurfaceError(CancellationError()))
    }

    /// `URLError(.cancelled)` 经网关层映射成 `MoviePilotError.ignore` —— **这条是重点**：
    /// 它不是 `CancellationError`，只 catch 前者挡不住。
    func testIgnoreErrorIsSilent() {
        let error = MoviePilotError(networkError: URLError(.cancelled) as NSError)
        guard case .ignore = error else {
            return XCTFail("`.cancelled` 应当映射成 .ignore，实际 \(error)")
        }
        XCTAssertFalse(
            DownloadsRefreshSurface.shouldSurfaceError(error),
            ".ignore 是「不显示」的语义，不该写成错误卡片")
    }

    /// 真错误照常显示 —— 别把下面这条顺手也改成 true。
    func testGenuineErrorsAreSurfaced() {
        let timeout = MoviePilotError(networkError: URLError(.timedOut) as NSError)
        XCTAssertTrue(DownloadsRefreshSurface.shouldSurfaceError(timeout))

        let noConnection = MoviePilotError(networkError: URLError(.notConnectedToInternet) as NSError)
        XCTAssertTrue(DownloadsRefreshSurface.shouldSurfaceError(noConnection))

        XCTAssertTrue(DownloadsRefreshSurface.shouldSurfaceError(MoviePilotError.requireLogin))

        // 非 MoviePilotError 的未知错误也要显示（不能因为「认不出」就吞掉）。
        struct Weird: Error {}
        XCTAssertTrue(DownloadsRefreshSurface.shouldSurfaceError(Weird()))
    }
}
