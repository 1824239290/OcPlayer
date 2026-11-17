import CoreModel
import PlaybackKit
import XCTest

@testable import OcPlayer

/// `P2-34`：`schedulePreparationDismiss` 轮询循环的**决策表**。
///
/// ## 为什么测决策函数而不是「时限」
///
/// 第一版只抽了「是否超时」一条并测它，结果（审查实测）：**把循环里对它的调用
/// 整段删掉，用例仍然全绿** —— 测试完全不在生产路径上。只测一个布尔表达式
/// 等于在测 `>` 运算符。
///
/// 现在循环的**每一个退出分支**都在 `preparationDismissDecision` 里，循环体只剩
/// 「取状态 → 调它 → 按结果清态返回」。所以下面这些表驱动用例覆盖的**就是生产
/// 逻辑本身**：任何一条分支被删或顺序被改错，都会红。
final class PreparationDismissDeadlineTests: XCTestCase {

    private typealias Decision = AppModel.PreparationDismissDecision
    private typealias App = AppModel

    /// 默认的一行输入：一切正常、正在等首帧、远未超时。
    private func decide(
        isCurrentRequest: Bool = true,
        hasPlayback: Bool = true,
        hasRenderedFirstFrame: Bool = false,
        state: PlaybackState = .opening,
        hasSetupError: Bool = false,
        playingSince: Duration? = nil,
        elapsed: Duration = .seconds(1),
        deadline: Duration = .seconds(90)
    ) -> Decision {
        App.preparationDismissDecision(
            isCurrentRequest: isCurrentRequest, hasPlayback: hasPlayback,
            hasRenderedFirstFrame: hasRenderedFirstFrame, state: state,
            hasSetupError: hasSetupError, playingSince: playingSince,
            elapsed: elapsed, deadline: deadline)
    }

    // MARK: - 逐分支

    /// 正常等待：什么特殊情况都没有 → 继续轮询。
    func testDefaultWaits() {
        XCTAssertEqual(decide(), .wait)
    }

    /// **分支 1：换片 / 关闭** → `.stop`（**不动** loading，它已归别的请求）。
    ///
    /// 若这里错成 `.clearLoading`，新请求的 loading 会被旧请求的循环清掉。
    func testStaleRequestStopsWithoutTouchingLoading() {
        XCTAssertEqual(decide(isCurrentRequest: false), .stop)
        // 即便同时「已出帧」或「已超时」，先判的仍应是 `.stop`。
        XCTAssertEqual(decide(isCurrentRequest: false, hasRenderedFirstFrame: true), .stop)
        XCTAssertEqual(decide(isCurrentRequest: false, elapsed: .seconds(999)), .stop)
    }

    /// **分支 2：控制器没了** → 清 loading（宁可退回两段式也别让 loading 永转）。
    func testMissingPlaybackClearsLoading() {
        XCTAssertEqual(decide(hasPlayback: false), .clearLoading)
    }

    /// **分支 3：首帧已上屏** → 清 loading，**无论 state**（哪怕已被暂停）。
    func testRenderedFirstFrameClearsRegardlessOfState() {
        for state in [PlaybackState.idle, .opening, .ready, .playing, .paused, .stopped, .closed, .error] {
            XCTAssertEqual(
                decide(hasRenderedFirstFrame: true, state: state), .clearLoading,
                "首帧已上屏时 state=\(state) 也应撤 loading")
        }
    }

    /// **分支 4：出错** → 清 loading，让错误徽章接管。
    func testErrorClearsLoading() {
        XCTAssertEqual(decide(state: .error), .clearLoading)
        XCTAssertEqual(decide(hasSetupError: true), .clearLoading)
    }

    /// **分支 5：playing 但迟迟无帧** → 宽限 2.5 s 后放行。
    func testPlayingWithoutFrameGivesGraceThenClears() {
        // 刚进 playing：还要等。
        XCTAssertEqual(decide(state: .playing, playingSince: .seconds(1), elapsed: .seconds(1)), .wait)
        // 宽限内：等。
        XCTAssertEqual(decide(state: .playing, playingSince: .seconds(1), elapsed: .seconds(3)), .wait)
        // 超过 2.5 s：清。
        XCTAssertEqual(decide(state: .playing, playingSince: .seconds(1), elapsed: .seconds(3.6)), .clearLoading)
    }

    /// **分支 6（`P2-34` 的核心）：超过总时限 → 清 loading。**
    ///
    /// 这条是「不会永久轮询」的保证。若它被删，下面 `.ready` 饿死的用例会红。
    func testDeadlineClearsLoading() {
        XCTAssertEqual(decide(elapsed: .seconds(91), deadline: .seconds(90)), .clearLoading)
        // 边界：恰好等于时限时**不**清（严格大于），多等一个 100 ms tick。
        XCTAssertEqual(decide(elapsed: .seconds(90), deadline: .seconds(90)), .wait)
        XCTAssertEqual(decide(elapsed: .seconds(90) + .nanoseconds(1), deadline: .seconds(90)),
                       .clearLoading)
    }

    // MARK: - 真实场景（为什么需要总时限）

    /// **`.ready` 饿死**：打开成功、内核已 init，但网络饿死迟迟不出帧又不报错。
    ///
    /// 这是**真实可达且原本无上限**的路径 —— 也是 `P2-34` 存在的理由。
    /// 没有时限分支，这里会永远是 `.wait`（10 Hz 永久轮询）。
    func testStarvedReadyStateEventuallyClears() {
        // 刚进入 ready：正常等待。
        XCTAssertEqual(decide(state: .ready, elapsed: .seconds(5)), .wait)
        // 一直不出帧、不报错、不进 playing —— 到时限必须清。
        XCTAssertEqual(decide(state: .ready, elapsed: .seconds(120)), .clearLoading)
    }

    /// **loading 期间被暂停在首帧前**：macOS 的键盘监听是全局的，
    /// loading 时按空格会 `pause()`，若此时尚无渲染帧，`hasRenderedFirstFrame` 永远 false。
    ///
    /// 所有非 playing 也非 error 的状态都该靠时限兜底。
    func testAllNonTerminalStatesAreBoundedByDeadline() {
        let stuckStates: [PlaybackState] = [.idle, .opening, .ready, .paused, .stopped, .closed]
        for state in stuckStates {
            XCTAssertEqual(
                decide(state: state, elapsed: .seconds(1)), .wait,
                "state=\(state) 刚开始应继续等")
            XCTAssertEqual(
                decide(state: state, elapsed: .seconds(120)), .clearLoading,
                "state=\(state) 卡住时必须在时限后清 loading —— 否则就是永久轮询")
        }
    }

    /// **有限时限一定收敛**：任何 state 组合下，elapsed 足够大时决策都不是 `.wait`。
    ///
    /// 这是「不会永久轮询」的形式化表述（不是同义反复 —— 它跑的是真实决策函数
    /// 的所有分支组合）。
    func testAlwaysConvergesEventually() {
        let deadline = Duration.seconds(90)
        let longPast = Duration.seconds(1000)
        for isCurrent in [true, false] {
            for hasPlayback in [true, false] {
                for hasFrame in [true, false] {
                    for state in [PlaybackState.idle, .opening, .ready, .playing, .paused,
                                  .stopped, .closed, .error] {
                        for hasError in [true, false] {
                            for since in [nil, Duration.seconds(0)] as [Duration?] {
                                let d = App.preparationDismissDecision(
                                    isCurrentRequest: isCurrent, hasPlayback: hasPlayback,
                                    hasRenderedFirstFrame: hasFrame, state: state,
                                    hasSetupError: hasError, playingSince: since,
                                    elapsed: longPast, deadline: deadline)
                                XCTAssertNotEqual(
                                    d, .wait,
                                    "isCurrent=\(isCurrent) hasPlayback=\(hasPlayback) "
                                        + "hasFrame=\(hasFrame) state=\(state) "
                                        + "hasError=\(hasError) since=\(String(describing: since)) "
                                        + "—— 1000 s 后仍在 wait = 永久轮询")
                            }
                        }
                    }
                }
            }
        }
    }

    /// **生产时限必须大于打开看门狗**（60 s）。
    ///
    /// 第一版设成 30 s 是**回归**：30 s 到点只撤 loading、`presentedPlayer` 不动 →
    /// 露出 `PlayerScreen`，而首帧没出、state 还是 `.opening`/`.ready`。
    /// `showsBufferingIndicator` 只对 `.playing` 为真，所以那 30 秒是
    /// **纯黑屏、无转圈、无文案**，直到 60 s 看门狗才出错误徽章。
    @MainActor
    func testDeadlineIsBeyondOpenWatchdog() {
        let deadline = AppModel.preparationDismissDeadline
        let watchdog = PlaybackController.openWatchdogDefault
        XCTAssertGreaterThan(
            deadline, watchdog,
            "loading 不能比看门狗先撤 —— 否则中间那段是无反馈黑屏")
    }
}
