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

    /// `.task(id:)` 的触发键必须**对三个相位各不相同** ——
    /// 相同的话相位变化不会重建任务，循环里读到的还是旧值（SwiftUI 的经典坑：
    /// `.task` 闭包捕获的是启动那一刻的视图快照）。
    func testTaskIDDistinguishesEveryPhase() {
        let ids: [Int] = [
            DownloadsPollingPolicy.taskID(.active),
            DownloadsPollingPolicy.taskID(.inactive),
            DownloadsPollingPolicy.taskID(.background),
        ]
        XCTAssertEqual(Set(ids).count, ids.count, "三个相位必须映射到不同的触发键：\(ids)")
    }

    /// 键与相位一一对应（固定值，改动会被这条钉住）。
    func testTaskIDValuesAreStable() {
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.active), 0)
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.inactive), 1)
        XCTAssertEqual(DownloadsPollingPolicy.taskID(.background), 2)
    }
}
