import CoreModel
import PlaybackKit
@testable import OcPlayer
import XCTest

/// iOS 前后台往返（进程被挂起再唤醒）的决策逻辑。
///
/// 真机上内核的音频出口 / 解码会话撑不过挂起这件事，单测复现不了；这里锁的是
/// 「回来该做什么」：决策表 + 意图簿记。改动这块时别把「自动接回去」退化成
/// 「弹错误徽章等用户点重试」。
@MainActor
final class AppBackgroundPlaybackTests: XCTestCase {

    // MARK: - 决策表

    func testForegroundResumeActionTable() {
        typealias Action = AppModel.ForegroundResumeAction
        func action(_ intent: Bool, _ state: PlaybackState?, setupError: Bool = false) -> Action {
            AppModel.foregroundResumeAction(
                intentToResume: intent, state: state, hasSetupError: setupError)
        }

        // 离开前没在播（用户自己按的暂停 / 本来就停在错误页）：前台一律不动，
        // 更不能顺手把一条旧错误又重试一遍。
        XCTAssertEqual(action(false, .playing), .none)
        XCTAssertEqual(action(false, .paused), .none)
        XCTAssertEqual(action(false, .error, setupError: true), .none)

        // 内核没撑过挂起 → 重建（和手动重试同一条路，只是不用用户点）。
        XCTAssertEqual(action(true, .error), .rebuild)
        XCTAssertEqual(action(true, .paused, setupError: true), .rebuild)

        // 健康 → 接着播。
        XCTAssertEqual(action(true, .paused), .resume)
        XCTAssertEqual(action(true, .ready), .resume)
        XCTAssertEqual(action(true, .playing), .resume)

        // 换片 / 已停 / 还没起播：不是「用户离开时正在看」，不做自动动作。
        XCTAssertEqual(action(true, .idle), .none)
        XCTAssertEqual(action(true, .opening), .none)
        XCTAssertEqual(action(true, .stopped), .none)
        XCTAssertEqual(action(true, .closed), .none)

        // 控制器还没装配 / 状态未知。
        XCTAssertEqual(action(true, nil), .none)
    }

    // MARK: - 意图簿记

    func testBackgroundWithoutControllerRecordsNoResumeIntent() {
        let app = AppModel()
        let request = PlaybackRequest(title: "ep-1", uri: "/tmp/ep1.mkv", resumeSeconds: 120)
        app.presentedPlayer = request

        _ = app.playbackDidEnterBackground()

        XCTAssertFalse(app.backgroundResumeIntent, "没有控制器就没有「离开时在播」这回事")
        XCTAssertNil(app.playbackPreparation, "进后台不该动准备态")
    }

    /// 控制器在、但引擎没起来（未播放 / 已停）：前台钩子必须空转，
    /// 不能因为「有控制器」就去重建一条根本没在播的会话。
    func testForegroundHookIsNoOpWhenPlaybackWasNotRunning() {
        let app = AppModel()
        let controller = PlaybackController()
        app.playback = controller
        let request = PlaybackRequest(title: "ep-1", uri: "/tmp/ep1.mkv")
        app.presentedPlayer = request
        app.playbackPreparation = nil

        _ = app.playbackDidEnterBackground()
        XCTAssertFalse(app.backgroundResumeIntent)

        app.playbackDidEnterForeground()

        XCTAssertFalse(app.backgroundResumeIntent, "前台钩子应当把意图消费掉")
        XCTAssertEqual(app.presentedPlayer?.id, request.id, "不该换请求")
        XCTAssertNil(app.playbackPreparation, "没在播就不该盖 loading 层")
    }
}
