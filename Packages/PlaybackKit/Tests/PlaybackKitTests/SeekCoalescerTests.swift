import XCTest
@testable import PlaybackKit

/// `SeekCoalescer` 的判定语义 + 「合并掉的那次不会到内核」这条边界。
///
/// 时间全部由用例显式给出（策略本身不读时钟），所以这些用例是确定性的、不 sleep。
/// 涉及「跨窗口」的时刻一律写成二进制可精确表示的数（0.125 / 0.25 / 0.375 …），
/// 免得 0.1 + 0.2 这类十进制误差把边界用例变成随机用例。
final class SeekCoalescerTests: XCTestCase {

    // MARK: - 判定语义

    /// 实测形态：同一落点、间隔几十毫秒的第二条被吞。
    func testDuplicateLandingInsideWindowIsCoalesced() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 120, at: 0), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 120, at: 0.031),
                       .coalesced(elapsedSinceForward: 0.031))
    }

    /// 一整串重复（每 < window 一条）只放行第一条 —— 这就是「同一拖动批次」的含义。
    func testBurstOfIdenticalLandingsCollapsesToTheFirst() {
        var coalescer = SeekCoalescer()
        var outcomes: [SeekCoalescer.Outcome] = []
        for step in 0..<6 {
            outcomes.append(coalescer.submit(landingSeconds: 300, at: Double(step) * 0.02))
        }
        XCTAssertEqual(outcomes.first, .forward)
        XCTAssertEqual(outcomes.dropFirst().filter { $0 == .forward }.count, 0,
                       "窗口内的后续重复都不该放行：\(outcomes)")
    }

    /// 不同落点必须全部放行：用户连续拖动每一段都要到内核。
    func testDistinctLandingsAreAllForwarded() {
        var coalescer = SeekCoalescer()
        for (index, landing) in [10.0, 20.0, 30.0, 25.0, 900.0].enumerated() {
            XCTAssertEqual(coalescer.submit(landingSeconds: landing, at: Double(index) * 0.01),
                           .forward, "落点 \(landing) 不是重复，必须放行")
        }
    }

    /// 距上次放行 ≥ 窗口后，同样落点必须放行（边界口径是「小于窗口才吞」）。
    func testSameLandingAfterWindowIsForwarded() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 42, at: 0), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 42, at: 0.25),
                       .coalesced(elapsedSinceForward: 0.25))
        XCTAssertEqual(coalescer.submit(landingSeconds: 42, at: 0.375), .forward,
                       "距上次放行 375 ms > 300 ms 窗口，必须放行")
        XCTAssertEqual(coalescer.submit(landingSeconds: 42, at: 0.4375),
                       .coalesced(elapsedSinceForward: 0.0625),
                       "放行后基准更新到 0.375")
    }

    /// 「先拖到 A、又拖回 A」：中间那次 B 是不同落点，它把基准从 A 换掉，
    /// 所以拖回 A 一定能到内核（本策略最容易被写错、最会吃掉真实意图的地方）。
    func testDraggingAwayAndBackToSameLandingIsForwarded() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 100, at: 0), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 260, at: 0.02), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 100, at: 0.04), .forward,
                       "A→B→A 全在窗口内，回 A 也是一次新意图")
    }

    /// 计时基准取「上次放行」的必然结果：重复风暴只被降频、不会被静音
    /// （每 window 至少放行一条），不存在「一直吞到用户松手」的死锁。
    func testSustainedDuplicateStormIsThrottledNotSilenced() {
        var coalescer = SeekCoalescer()
        var forwarded = 0
        for step in 0...8 {  // 每 125 ms 一条相同落点，共 1 s
            if coalescer.submit(landingSeconds: 500, at: Double(step) * 0.125) == .forward {
                forwarded += 1
            }
        }
        XCTAssertEqual(forwarded, 3, "0 / 0.375 / 0.75 各放行一条")
    }

    /// 落点同一性量化到毫秒：日志 `to_ms` 相同的两次拖动必须算重复，
    /// 而 1 ms 以上的差异是另一个落点。
    func testLandingIdentityIsQuantizedToMilliseconds() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 120.0, at: 0), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 120.0004, at: 0.01),
                       .coalesced(elapsedSinceForward: 0.01),
                       "ms 量化后是同一落点：Double 不相等也要算重复")
        XCTAssertEqual(coalescer.submit(landingSeconds: 120.001, at: 0.02), .forward,
                       "差 1 ms 已经是另一个落点")
    }

    /// 参数写错时宁可不合并：窗口非正 / 非有限 ⇒ 全部放行。
    func testNonPositiveOrInvalidWindowDisablesCoalescing() {
        for window in [0.0, -1.0, Double.nan, Double.infinity] {
            var coalescer = SeekCoalescer(window: window)
            XCTAssertEqual(coalescer.submit(landingSeconds: 7, at: 0), .forward, "window=\(window)")
            XCTAssertEqual(coalescer.submit(landingSeconds: 7, at: 0), .forward, "window=\(window)")
        }
    }

    /// 无效落点 / 无效时刻：放行，且不污染基准（基准仍是上一次真正放行的那次）。
    func testInvalidInputIsForwardedWithoutPollutingTheBaseline() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 8), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: .nan, at: 8.0625), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 8.125),
                       .coalesced(elapsedSinceForward: 0.125),
                       "无效落点没污染基准：仍与 (88, 8) 比")
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: .nan), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 8.1875),
                       .coalesced(elapsedSinceForward: 0.1875),
                       "无效时刻同样不更新基准：间隔仍从 8 起算，不是从 8.125")
    }

    /// 非单调时钟导致的时间倒流：一律放行（吞掉的代价是用户动作丢失，
    /// 多打一次内核的代价小得多，两者不对等）。
    func testClockGoingBackwardsForwardsInsteadOfSwallowing() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 10), .forward)
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 9), .forward,
                       "时间倒流按放行处理")
        XCTAssertEqual(coalescer.submit(landingSeconds: 88, at: 9.125),
                       .coalesced(elapsedSinceForward: 0.125),
                       "倒流那一次自身是放行的，基准随之更新到 9")
    }

    func testResetDropsTheBaseline() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 60, at: 0), .forward)
        coalescer.reset()
        XCTAssertEqual(coalescer.submit(landingSeconds: 60, at: 0.01), .forward)
    }

    func testFiniteLandingOutsideMillisecondRangeDoesNotTrapOrChangeBaseline() {
        var coalescer = SeekCoalescer()
        XCTAssertEqual(coalescer.submit(landingSeconds: 60, at: 0), .forward)
        for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                      Double(Int64.max) / 1000] {
            XCTAssertEqual(coalescer.submit(landingSeconds: value, at: 0.01), .forward)
        }
        XCTAssertEqual(coalescer.submit(landingSeconds: 60, at: 0.02),
                       .coalesced(elapsedSinceForward: 0.02))
    }

    /// 默认窗口就是任务约定的 300 ms（改它必须是有意识的决定）。
    func testDefaultWindowIsThreeHundredMilliseconds() {
        XCTAssertEqual(SeekCoalescer.defaultWindow, 0.3)
        XCTAssertEqual(SeekCoalescer().window, 0.3)
    }

    // MARK: - 边界：被吞掉的那次不产生第二次内核调用

    /// 走一遍 `PlaybackController.seek(toFraction:)` 的链路：放行才调 `engine.seek`。
    @discardableResult
    private func drive(_ submissions: [(landingSeconds: Double, time: TimeInterval)],
                       window: TimeInterval = SeekCoalescer.defaultWindow,
                       into engine: FakePlaybackEngine) -> (forwarded: Int, coalesced: Int) {
        var coalescer = SeekCoalescer(window: window)
        var forwarded = 0
        var coalesced = 0
        for submission in submissions {
            switch coalescer.submit(landingSeconds: submission.landingSeconds, at: submission.time) {
            case .forward:
                forwarded += 1
                try? engine.seek(to: .seconds(submission.landingSeconds))
            case .coalesced:
                coalesced += 1
            }
        }
        return (forwarded, coalesced)
    }

    func testCoalescedDuplicateNeverReachesTheEngine() {
        let engine = FakePlaybackEngine()
        let result = drive([(landingSeconds: 120, time: 0), (landingSeconds: 120, time: 0.031)],
                           into: engine)
        XCTAssertEqual(result.forwarded, 1)
        XCTAssertEqual(result.coalesced, 1)
        XCTAssertEqual(engine.seekTargets, [Duration.seconds(120)], "内核只该被调一次")
    }

    /// 回归：2026-11-07 实测的 11 次拖动 = 22 条 scrub（同对的 from_ms/to_ms 逐字相同，
    /// 间隔 2~43 ms）。合并后内核只被调 11 次（此前 22 次），且每次落点都是用户真正拖到的地方。
    func testObservedDuplicatePairsCollapseToElevenEngineCalls() {
        // 逐条抄自 ~/Library/Logs/OcPlayer/diagnostics-20261107-142219-e32c398a.jsonl
        // （landingMS = 该对逐字相同的 to_ms；gapMS = 两条之间的实测间隔）
        let observedPairs: [(landingMS: Double, gapMS: Double)] = [
            (75757, 43), (92364, 41), (88943, 2), (109189, 27), (147078, 26), (125625, 27),
            (125278, 26), (115501, 27), (105627, 28), (94908, 37), (113875, 27),
        ]
        var submissions: [(landingSeconds: Double, time: TimeInterval)] = []
        var clock = 0.0
        for pair in observedPairs {
            let landing = pair.landingMS / 1000
            submissions.append((landingSeconds: landing, time: clock))
            clock += pair.gapMS / 1000
            submissions.append((landingSeconds: landing, time: clock))
            clock += 0.5  // 两次拖动之间的真实间隔远大于窗口
        }
        let engine = FakePlaybackEngine()
        let result = drive(submissions, into: engine)
        XCTAssertEqual(submissions.count, 22)
        XCTAssertEqual(result.forwarded, 11)
        XCTAssertEqual(result.coalesced, 11)
        XCTAssertEqual(engine.seekTargets.count, 11)
        XCTAssertEqual(engine.seekTargets.first, Duration.seconds(75.757))
        XCTAssertEqual(engine.seekTargets.last, Duration.seconds(113.875))
    }

    /// 连续拖动（每一段落点都不同）不能被吞掉任何一段。
    func testContinuousDragDeliversEveryDistinctLanding() {
        let submissions: [(landingSeconds: Double, time: TimeInterval)] =
            (0...10).map { (landingSeconds: 600.0 * Double($0) / 10.0, time: Double($0) * 0.02) }
        let engine = FakePlaybackEngine()
        let result = drive(submissions, into: engine)
        XCTAssertEqual(result.coalesced, 0)
        XCTAssertEqual(engine.seekTargets.count, 11)
    }

    /// 落点不同但**间隔也在窗口内**的拖动同样全部放行
    /// （重复判定必须同时看落点与时间，不能只看时间）。
    func testDifferentLandingsInsideWindowAreAllDelivered() {
        let engine = FakePlaybackEngine()
        let result = drive([
            (landingSeconds: 60, time: 0),
            (landingSeconds: 61, time: 0.005),
            (landingSeconds: 62, time: 0.01),
            (landingSeconds: 63, time: 0.015),
        ], into: engine)
        XCTAssertEqual(result.forwarded, 4)
        XCTAssertEqual(result.coalesced, 0)
        XCTAssertEqual(engine.seekTargets.count, 4)
    }
}
