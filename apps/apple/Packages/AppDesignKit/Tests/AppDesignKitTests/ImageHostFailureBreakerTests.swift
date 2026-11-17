import XCTest

@testable import AppDesignKit

/// `ImageHostFailureBreaker`：按 host 的失败熔断 + 冷却 / 半开。
///
/// 时间全部走 `at:` 参数注入，用例不 sleep —— 冷却窗口的语义（「什么时候放行」
/// 「放行几个」）必须能精确断言，而不是靠等。
final class ImageHostFailureBreakerTests: XCTestCase {

    private let host = URL(string: "https://media.example.com/Items/a/Images/Primary")!
    private let otherPath = URL(string: "https://media.example.com/Items/b/Images/Primary")!
    private let otherHost = URL(string: "https://cdn.example.net/a.png")!

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// 连续失败到阈值才熔断；阈值以下一律放行。
    func testCircuitOpensAtThreshold() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 3, cooldown: 30)

        breaker.recordFailure(for: host, at: start)
        breaker.recordFailure(for: host, at: start)
        XCTAssertTrue(
            breaker.shouldAllowRequest(for: host, at: start),
            "两次失败还不该熔断，否则一次网络抖动就会让整墙海报停摆")

        breaker.recordFailure(for: host, at: start)
        XCTAssertFalse(
            breaker.shouldAllowRequest(for: host, at: start),
            "第三次连续失败后必须立刻停止再发请求（否则每张图各等一次 15 秒超时）")
    }

    /// 熔断按 host 记，不是全局：一个图床挂了不该连累别的服务器。
    func testCircuitsAreIsolatedPerHost() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 60)
        breaker.recordFailure(for: host, at: start)

        XCTAssertFalse(breaker.shouldAllowRequest(for: otherPath, at: start), "同一 host 应一起熔断")
        XCTAssertTrue(breaker.shouldAllowRequest(for: otherHost, at: start), "别的 host 必须照常放行")
    }

    /// 冷却期间所有请求都拒；到期只放行**一个**半开探针。
    func testCooldownExpiryAllowsExactlyOneProbe() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)

        XCTAssertFalse(
            breaker.shouldAllowRequest(for: host, at: start.addingTimeInterval(29.9)),
            "冷却未到不该放行")
        XCTAssertTrue(
            breaker.shouldAllowRequest(for: host, at: start.addingTimeInterval(30.1)),
            "冷却到期后第一个请求是探针")
        XCTAssertFalse(
            breaker.shouldAllowRequest(for: otherPath, at: start.addingTimeInterval(30.2)),
            "探针在途时其余请求继续拒，否则会瞬间打出一整墙请求")
    }

    /// 探针失败 → 从**探针失败的时刻**重开完整冷却，而不是沿用旧的 `openedAt`。
    func testFailedProbeRestartsFullCooldown() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)

        let probeAt = start.addingTimeInterval(31)
        XCTAssertTrue(breaker.shouldAllowRequest(for: host, at: probeAt))
        breaker.recordFailure(for: host, at: probeAt)

        XCTAssertFalse(
            breaker.shouldAllowRequest(for: host, at: probeAt.addingTimeInterval(10)),
            "探针失败后要重新等满一个冷却窗口")
        XCTAssertTrue(
            breaker.shouldAllowRequest(for: host, at: probeAt.addingTimeInterval(30.1)))
    }

    /// 探针成功 → 计数与熔断一起复位，之后所有请求放行。
    func testSuccessfulProbeClosesCircuit() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)

        let probeAt = start.addingTimeInterval(31)
        XCTAssertTrue(breaker.shouldAllowRequest(for: host, at: probeAt))
        breaker.recordSuccess(for: host)

        for offset in [0.0, 1, 60, 600] {
            XCTAssertTrue(
                breaker.shouldAllowRequest(for: host, at: probeAt.addingTimeInterval(offset)),
                "host 已恢复，不该再熔断")
        }
        let snapshot = breaker.snapshot(for: host, at: probeAt)
        XCTAssertFalse(snapshot.isOpen)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
    }

    /// 成功会清掉**未到阈值**的失败计数：断断续续的失败不该攒成一次熔断。
    func testSuccessResetsFailureCountBelowThreshold() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 3, cooldown: 60)
        breaker.recordFailure(for: host, at: start)
        breaker.recordFailure(for: host, at: start)
        breaker.recordSuccess(for: host)

        XCTAssertEqual(breaker.snapshot(for: host, at: start).consecutiveFailures, 0)
        breaker.recordFailure(for: host, at: start)
        breaker.recordFailure(for: host, at: start)
        XCTAssertTrue(
            breaker.shouldAllowRequest(for: host, at: start),
            "复位后重新计数：两次失败仍不该熔断")
    }

    /// 探针被取消 = 没有结论：`releaseProbe` 要能把探针位还回来。
    ///
    /// 没有这一条，一次「滚动带走了这张图」就会把 host 永久钉死在
    /// 「冷却已过、探针在途」上，之后所有请求都被拒——比不熔断更糟。
    func testReleasedProbeLetsNextRequestTry() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)

        let probeAt = start.addingTimeInterval(31)
        XCTAssertTrue(breaker.shouldAllowRequest(for: host, at: probeAt))
        XCTAssertFalse(breaker.shouldAllowRequest(for: host, at: probeAt), "探针在途，第二个请求拒")

        breaker.releaseProbe(for: host)
        let released = breaker.snapshot(for: host, at: probeAt)
        XCTAssertTrue(released.isOpen, "释放探针不等于关闭熔断：这个 host 还没有成功过")
        XCTAssertFalse(released.probeInFlight, "探针位必须还回来了")

        XCTAssertTrue(
            breaker.shouldAllowRequest(for: host, at: probeAt),
            "探针位释放后必须能再试，否则该 host 永久黑掉")
        XCTAssertFalse(
            breaker.shouldAllowRequest(for: host, at: probeAt),
            "新探针在途时，其余请求继续拒")
    }

    /// 已打开后继续到达的失败（打开前就在途的请求）要顺延冷却，避免刚放行又立刻全放。
    func testLateFailureWhileOpenExtendsCooldown() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)
        XCTAssertFalse(breaker.shouldAllowRequest(for: host, at: start))

        breaker.recordFailure(for: host, at: start.addingTimeInterval(10))
        XCTAssertFalse(
            breaker.shouldAllowRequest(for: host, at: start.addingTimeInterval(35)),
            "冷却应从最新一次失败算起（10 + 30 > 35）")
        XCTAssertTrue(breaker.shouldAllowRequest(for: host, at: start.addingTimeInterval(41)))
    }

    /// `snapshot` 的剩余冷却时间是给观测/日志用的，别算错方向。
    func testSnapshotReportsRemainingCooldown() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 30)
        breaker.recordFailure(for: host, at: start)

        let snapshot = breaker.snapshot(for: host, at: start.addingTimeInterval(12))
        XCTAssertTrue(snapshot.isOpen)
        XCTAssertEqual(snapshot.cooldownRemaining, 18, accuracy: 0.001)
        XCTAssertFalse(snapshot.probeInFlight)

        let afterProbe = breaker.snapshot(for: host, at: start.addingTimeInterval(31))
        XCTAssertEqual(afterProbe.cooldownRemaining, 0)
    }

    /// 没有 host 的 URL（`file:` / 相对路径）一律放行：熔断只对网络宿主有意义。
    func testURLAuthoredWithoutHostIsAlwaysAllowed() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 60)
        let local = URL(fileURLWithPath: "/tmp/poster.png")
        breaker.recordFailure(for: local)
        XCTAssertTrue(breaker.shouldAllowRequest(for: local))
    }

    /// 大小写不同的 host 是同一个 host（缓存键规范化只处理 URL，不处理熔断键）。
    func testHostKeysAreCaseInsensitive() {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 60)
        breaker.recordFailure(for: URL(string: "https://Media.Example.COM/a.png")!)
        XCTAssertFalse(breaker.shouldAllowRequest(for: URL(string: "https://media.example.com/b.png")!))
    }
}
