import Foundation
import XCTest
@testable import OcPlayer

/// 更新检查的节流与取消语义（review-20260914 P3-1）。
@MainActor
final class AppUpdateCheckerTests: XCTestCase {

    private func makeChecker(
        defaults: UserDefaults,
        checkInterval: TimeInterval = 24 * 60 * 60
    ) -> AppUpdateChecker {
        AppUpdateChecker(
            repoOwner: "test",
            repoName: "test",
            session: URLSession(configuration: TestSupport.mockedSessionConfiguration()),
            defaults: defaults,
            checkInterval: checkInterval
        )
    }

    /// 让 GitHub 回一个比当前版本旧、但能走完成功路径的 Release（state = .upToDate）。
    private func respondWithRelease(tag: String, counter: RequestCounter) {
        MockURLProtocol.handler = { request in
            counter.increment()
            return TestSupport.response(
                TestSupport.releaseJSON(tag: tag), status: 200, for: request.url!)
        }
    }

    func testCancelledRequestResetsStateToIdle() async {
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let checker = makeChecker(
            defaults: TestSupport.isolatedDefaults("AppUpdateCheckerTests.cancelled"))

        await checker.checkForUpdates()

        XCTAssertEqual(checker.state, .idle, "取消要静默回 idle，而不是钉死错误态")
        XCTAssertNil(checker.lastCheckedDate, "取消不算「检查过」，不落节流时间戳")
    }

    func testAutoCheckThrottledWithinInterval() async {
        let counter = RequestCounter()
        respondWithRelease(tag: "v0.0.1", counter: counter)
        let checker = makeChecker(
            defaults: TestSupport.isolatedDefaults("AppUpdateCheckerTests.throttle"))

        await checker.checkForUpdates()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(checker.state, .upToDate(version: "v0.0.1"))

        await checker.checkForUpdates()
        XCTAssertEqual(counter.count, 1, "节流窗口内不该再打 GitHub API")
        XCTAssertEqual(checker.state, .upToDate(version: "v0.0.1"))
    }

    func testUserInitiatedCheckBypassesThrottle() async {
        let counter = RequestCounter()
        respondWithRelease(tag: "v0.0.1", counter: counter)
        let checker = makeChecker(
            defaults: TestSupport.isolatedDefaults("AppUpdateCheckerTests.userInitiated"))

        await checker.checkForUpdates()
        await checker.checkForUpdates(isUserInitiated: true)

        XCTAssertEqual(counter.count, 2, "用户点按钮不受节流限制")
    }

    func testAutoCheckResumesAfterInterval() async {
        let counter = RequestCounter()
        respondWithRelease(tag: "v0.0.1", counter: counter)
        let checker = makeChecker(
            defaults: TestSupport.isolatedDefaults("AppUpdateCheckerTests.expired"),
            checkInterval: 0)

        await checker.checkForUpdates()
        await checker.checkForUpdates()

        XCTAssertEqual(counter.count, 2, "过了间隔就该放行")
    }

    func testFailedCheckDoesNotStamp() async {
        let counter = RequestCounter()
        MockURLProtocol.handler = { _ in
            counter.increment()
            throw URLError(.timedOut)
        }
        let checker = makeChecker(
            defaults: TestSupport.isolatedDefaults("AppUpdateCheckerTests.failure"))

        await checker.checkForUpdates()
        XCTAssertEqual(checker.state, .failed("网络超时"))
        XCTAssertNil(checker.lastCheckedDate, "失败不打时间戳")

        await checker.checkForUpdates()
        XCTAssertEqual(counter.count, 2, "失败不留痕 → 下次自动检查仍会重试")
    }

    func testIgnoredVersionPersistsInInjectedDefaults() {
        let defaults = TestSupport.isolatedDefaults("AppUpdateCheckerTests.ignored")
        let checker = makeChecker(defaults: defaults)

        checker.ignoreVersion("v1.5.0")
        XCTAssertEqual(checker.ignoredVersion, "v1.5.0")
        XCTAssertEqual(
            defaults.string(forKey: SettingsKeys.updateIgnoredVersion), "v1.5.0",
            "忽略记录要落在注入的域里")

        checker.clearIgnoredVersion()
        XCTAssertNil(checker.ignoredVersion)
    }
}
