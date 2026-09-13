import XCTest
@testable import DanmakuKit

/// 片头提示检测器的用例取自 2026-09-13 真实缓存弹幕的标定数据
/// （54 集扫描：报点主簇中位数与「空降成功」着陆确认逐秒吻合）。
final class DanmakuIntroDetectorTests: XCTestCase {

    private func comment(_ time: Double, _ text: String) -> DanmakuComment {
        DanmakuComment(cid: nil, p: "\(time),1,16777215,user", m: text)
    }

    // MARK: 真实形态回归

    func testJumpPostsClusterMedianWithLandingConfirmation() {
        // 猫与龙 第8话：报点 02:12/02:13 全角半角混杂，着陆确认 22 条。
        var comments = [
            comment(1.7, "空降2.10"),
            comment(2.9, "空降02：12"),
            comment(40.5, "空降02:08"),
            comment(42.1, "空降02:13"),
            comment(42.3, "跳伞02:12"),
            comment(42.8, "跳伞 02:12"),
            comment(44.2, "跳伞02:12"),
            comment(45.7, "空降2：13"),
            comment(131.1, "空降：02：12"),
            comment(136.4, "空降2:15"),
        ]
        comments.append(contentsOf: (0..<22).map { comment(131.0 + Double($0) * 0.3, "空降成功") })
        comments.append(comment(600, "这集作画炸裂"))

        let hint = DanmakuIntroDetector.detect(in: comments)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.endSeconds, 132)
        // 最早报点帖在 1.7s → 起点估计 0（无冷开场）。
        XCTAssertEqual(hint?.startSeconds, 0)
        XCTAssertGreaterThanOrEqual(hint?.evidenceCount ?? 0, 10)
    }

    func testColdOpenEpisodeEstimatesNonZeroStart() {
        // Re:0 第14话：前情回顾 + 长 OP，报点帖集中在前情段末尾出现。
        let comments = [
            comment(50, "上集的战斗好帅"),
            comment(100.1, "空降3:20"),
            comment(107.1, "跳伞3:18"),
            comment(107.8, "跳伞03:17"),
            comment(108.9, "空降03:18"),
            comment(109.5, "跳伞3：11"),
            comment(110.2, "空降3：18"),
            comment(112.8, "空降 03:18"),
            comment(114.2, "空降03:18"),
            comment(116.3, "空降3：18"),
            comment(196.8, "空降成功，反手炸掉指挥部"),
            comment(197.3, "空降成功，感谢指挥部"),
            comment(198.9, "空降成功，感谢指挥部"),
        ]
        let hint = DanmakuIntroDetector.detect(in: comments)
        XCTAssertEqual(hint?.endSeconds, 198)
        XCTAssertEqual(hint?.startSeconds, 98)
    }

    func testOutlierJumpTargetsAreRejected() {
        // 躲在超市 第7话：主簇 02:2x 附近，混入片尾玩笑报点与无关数字。
        let comments = [
            comment(57.5, "空降02:28"),
            comment(58.6, "跳伞2:35"),
            comment(59.3, "跳伞02：29"),
            comment(0.0, "跳伞22:17"),
            comment(1.8, "跳伞22:17"),
            comment(59.5, "跳伞22:17"),
            comment(62.1, "跳伞02:35"),
            comment(66.8, "跳伞2:29"),
            comment(20.6, "跳伞00:19"),
            comment(151.0, "感谢指挥部，我已空降，状态良好"),
            comment(153.5, "空降成功"),
        ]
        let hint = DanmakuIntroDetector.detect(in: comments)
        // 主簇 [148,149,149,155,155] 的中位数是 149（与真实标定一致）。
        XCTAssertEqual(hint?.endSeconds, 149)
    }

    // MARK: 解析细节

    func testTimestampVariants() {
        // 全角冒号 / 点分隔两位秒 / 单数字秒（冒号）都合法。
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp("02：12"), 132)
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp("2.21"), 141)
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp("2.10"), 130)
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp("3:9"), 189)
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp(" 03:18"), 198)
        XCTAssertEqual(DanmakuIntroDetector.parseTimestamp("：02：12"), 132)
        // 点分隔 + 单数字秒不是时间戳（「跳伞1.5倍」防误伤）。
        XCTAssertNil(DanmakuIntroDetector.parseTimestamp("1.5倍好听"))
        XCTAssertNil(DanmakuIntroDetector.parseTimestamp("2.5"))
        // 非法分钟/秒。
        XCTAssertNil(DanmakuIntroDetector.parseTimestamp("75:99"))
    }

    func testJumpTargetScansOnlyAfterKeyword() {
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "跳伞至3:17"), 197)
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "指挥部骗人啊，这给我空降到哪来了"), nil)
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "这里咋没跳伞"), nil)
        // 关键词后 12 字符内才扫时间戳。
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "空降哈啊啊啊啊啊啊啊啊啊啊啊02:12"), nil)
    }

    // MARK: 弱信号拒绝

    func testWeakSignalsAreRejected() {
        // 单条报点不可信。
        XCTAssertNil(DanmakuIntroDetector.detect(in: [comment(42, "跳伞02:12")]))
        // 两条报点但目标值相同（同人复读）且无确认 → distinct=1。
        XCTAssertNil(DanmakuIntroDetector.detect(in: [
            comment(42, "跳伞02:12"),
            comment(45, "跳伞02:12"),
        ]))
        // 两个不同目标但都无确认、无着陆 → 不足 3 个目标值。
        XCTAssertNil(DanmakuIntroDetector.detect(in: [
            comment(42, "跳伞02:12"),
            comment(45, "跳伞02:14"),
        ]))
        // 完全无信号。
        XCTAssertNil(DanmakuIntroDetector.detect(in: [
            comment(10, "OP好听"), comment(90, "不跳OP我骄傲"),
        ]))
        XCTAssertNil(DanmakuIntroDetector.detect(in: []))
    }

    func testTwoDistinctTargetsWithConfirmationAreAccepted() {
        let comments = [
            comment(40, "跳伞02:12"),
            comment(44, "跳伞02:13"),
            comment(131, "空降成功"),
        ]
        let hint = DanmakuIntroDetector.detect(in: comments)
        // 132 与 133 的中位数取整后是 133。
        XCTAssertEqual(hint?.endSeconds, 133)
        XCTAssertEqual(hint?.evidenceCount, 3)
    }

    func testLandingOnlyPathWithoutJumpTargets() {
        let comments = [
            comment(94.2, "空降成功"),
            comment(94.5, "空降完成"),
            comment(95.0, "感谢指挥部，已空降"),
            comment(200, "正片好看"),
        ]
        let hint = DanmakuIntroDetector.detect(in: comments)
        XCTAssertEqual(hint?.endSeconds, 95)
        XCTAssertNil(hint?.startSeconds)
    }

    func testStartEstimateDroppedWhenWindowUnreasonable() {
        // 最早报点帖出现在片头末尾 → 起点估计无意义，回 nil。
        let comments = [
            comment(128, "跳伞02:12"),
            comment(130, "跳伞02:13"),
            comment(131, "空降成功"),
        ]
        let hint = DanmakuIntroDetector.detect(in: comments)
        // 起点估计窗口太短被丢弃；终点仍是主簇中位数取整（132.5 → 133）。
        XCTAssertEqual(hint?.endSeconds, 133)
        XCTAssertNil(hint?.startSeconds)
    }
}
