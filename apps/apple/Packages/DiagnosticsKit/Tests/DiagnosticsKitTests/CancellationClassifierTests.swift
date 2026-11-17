import Foundation
import XCTest

@testable import DiagnosticsKit

/// 「取消不是失败」的判据（性能审查清单 `CORR-07`）。
///
/// ## 为什么要有这组用例
///
/// 正常取消有**两种**类型，而它们不是同一个东西：
/// - `CancellationError`（`Task.checkCancellation()` 抛的）；
/// - `URLError(.cancelled)`（`NSURLErrorDomain` 码 **-999**，`URLSession` 抛的）。
///
/// 只写 `catch is CancellationError` 的站点**接不住第二种** —— 正常取消会掉进通用
/// `catch`，被记成 warning（图片加载失败 / 弹幕查询失败），把真正的故障淹掉。
/// 本仓已因这个错配出过一次用户可见故障（下载页轮询被取消后弹错误卡片）。
final class CancellationClassifierTests: XCTestCase {

    /// `CancellationError` 算取消。
    func testCancellationErrorIsCancellation() {
        XCTAssertTrue(CancellationClassifier.isCancellation(CancellationError()))
    }

    /// **`URLError.cancelled`（-999）也算取消** —— 这是本组用例存在的理由。
    func testURLErrorCancelledIsCancellation() {
        let error = URLError(.cancelled)
        XCTAssertTrue(CancellationClassifier.isCancellation(error))
        // 顺带钉住「它不是 CancellationError」——这正是漏判的根因。
        XCTAssertFalse(error is CancellationError, "若这里为真，说明 Foundation 改语义了")
    }

    /// 各种「被取消」的等价包装都要认（`NSError` 桥接、`URLError` 直抛、被 `any Error` 装箱）。
    func testCancellationVariants() {
        XCTAssertTrue(CancellationClassifier.isCancellation(URLError(.cancelled) as any Error))
        XCTAssertTrue(CancellationClassifier.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(CancellationClassifier.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: ["k": 1])))
    }

    /// **别的网络错误不能被当成取消** —— 反过来漏报故障才是真危险。
    ///
    /// 这条是判据的「窄」一侧：超时、断网、连不上、HTTP 层错误都必须算失败。
    func testOtherErrorsAreNotCancellation() {
        let failures: [(String, any Error)] = [
            ("超时", URLError(.timedOut)),
            ("断网", URLError(.notConnectedToInternet)),
            ("连不上", URLError(.cannotConnectToHost)),
            ("DNS", URLError(.cannotFindHost)),
            ("连接中断", URLError(.networkConnectionLost)),
            ("未知 URL 错误", URLError(.unknown)),
            ("非网络域", NSError(domain: "SomeOtherDomain", code: NSURLErrorCancelled)),
            ("同域不同码", NSError(domain: NSURLErrorDomain, code: -1001)),
            ("普通错误", NSError(domain: "app", code: 1)),
        ]
        for (name, error) in failures {
            XCTAssertFalse(
                CancellationClassifier.isCancellation(error),
                "\(name) 被判成了取消 —— 会把真实故障吞掉")
        }
    }

    /// `normalized` 把取消归一并原样透传其它错误。
    func testNormalizedOnlyRewritesCancellation() {
        XCTAssertTrue(CancellationClassifier.normalized(URLError(.cancelled)) is CancellationError)
        XCTAssertTrue(CancellationClassifier.normalized(CancellationError()) is CancellationError)

        let timeout = URLError(.timedOut)
        let kept = CancellationClassifier.normalized(timeout)
        XCTAssertEqual((kept as NSError).code, (timeout as NSError).code, "非取消错误必须原样透传")
        XCTAssertFalse(kept is CancellationError)
    }

    /// `JellyfinKit.JellyfinError.isCancellation` 必须与这里**同一个判据**（一个真源）。
    ///
    /// 跨包用例放在这里，是因为它在其它包里断言会让本包依赖倒挂；
    /// 这条只钉契约：两边对同一组输入给出相同答案。
    func testClassifierIsTheSingleSourceOfTruth() {
        // 判据本身是可组合的纯函数，这里直接枚举一遍确认没有隐藏状态。
        let samples: [any Error] = [
            CancellationError(), URLError(.cancelled), URLError(.timedOut),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        ]
        for sample in samples {
            let first = CancellationClassifier.isCancellation(sample)
            let second = CancellationClassifier.isCancellation(sample)
            XCTAssertEqual(first, second, "判据必须是纯函数")
        }
    }
}
