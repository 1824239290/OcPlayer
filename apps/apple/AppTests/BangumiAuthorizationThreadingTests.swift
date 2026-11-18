#if os(macOS)
import Foundation
import Observation
import XCTest
@testable import OcPlayer

@MainActor
final class BangumiAuthorizationThreadingTests: XCTestCase {
    func testAcceptedBrowserCallbackCanRunOffMainThread() async {
        let coordinator = BangumiCoordinator()
        coordinator.authError = "existing error"
        let completion = BangumiAccountLoginRow.authorizationCompletion(for: coordinator)
        let completed = expectation(description: "background browser callback returned")

        DispatchQueue(label: "BangumiAuthorizationThreadingTests.accepted").async {
            XCTAssertFalse(Thread.isMainThread)
            completion(true)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(coordinator.authError, "existing error")
    }

    func testRejectedBrowserCallbackUpdatesErrorOnMainActor() async {
        let coordinator = BangumiCoordinator()
        let completion = BangumiAccountLoginRow.authorizationCompletion(for: coordinator)
        let errorChanged = expectation(description: "browser failure reached UI state")
        withObservationTracking {
            _ = coordinator.authError
        } onChange: {
            errorChanged.fulfill()
        }

        DispatchQueue(label: "BangumiAuthorizationThreadingTests.rejected").async {
            XCTAssertFalse(Thread.isMainThread)
            completion(false)
        }

        await fulfillment(of: [errorChanged], timeout: 3)
        XCTAssertEqual(coordinator.authError, "无法打开默认浏览器，请重试。")
    }
}
#endif
