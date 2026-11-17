import Foundation
import XCTest
@testable import DiagnosticsKit

/// 跨包共享的网络工具：错误码分类、请求日志、Duration 换算。
final class NetworkCommonTests: XCTestCase {

    // MARK: - NetworkErrorClassifier

    func testClassifierMapsCommonCodes() {
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorNotConnectedToInternet), .noConnection)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorTimedOut), .timedOut)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorCannotFindHost), .cannotResolveHost)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorDNSLookupFailed), .cannotResolveHost)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorCannotConnectToHost), .cannotConnect)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorNetworkConnectionLost), .cannotConnect)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorSecureConnectionFailed), .secureConnectionFailed)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorServerCertificateUntrusted), .secureConnectionFailed)
        XCTAssertEqual(NetworkErrorClassifier.kind(for: NSURLErrorCancelled), .cancelled)
    }

    func testClassifierReturnsNilForUnknown() {
        XCTAssertNil(NetworkErrorClassifier.kind(for: NSURLErrorBadURL))
        XCTAssertNil(NetworkErrorClassifier.kind(for: 42_424_242))
    }

    func testClassifierCoversAllCertificateCases() {
        let codes = [
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorCannotLoadFromNetwork,
        ]
        for code in codes {
            XCTAssertEqual(NetworkErrorClassifier.kind(for: code), .secureConnectionFailed, "code=\(code)")
        }
    }

    // MARK: - NetworkLog

    func testLogPathDropsQueryAndTrailingSlash() {
        XCTAssertEqual(NetworkLog.logPath(for: URL(string: "/Items?userId=abc")), "/Items")
        XCTAssertEqual(NetworkLog.logPath(for: URL(string: "/api/v1/subscribe/")), "/api/v1/subscribe")
    }

    func testLogPathFallsBackSafely() {
        XCTAssertEqual(NetworkLog.logPath(for: nil), "?")
        // 整条 URL 只有 query（path 为空）时退回 absoluteString，避免丢信息。
        let queryOnly = URL(string: "https://host.example.com")!
        XCTAssertEqual(NetworkLog.logPath(for: queryOnly), "https://host.example.com")
    }

    // MARK: - Duration

    func testDurationTimeInterval() {
        let d = Duration(secondsComponent: 1, attosecondsComponent: 0)
        XCTAssertEqual(d.timeInterval, 1.0, accuracy: 1e-9)
        let half = Duration.milliseconds(500)
        XCTAssertEqual(half.timeInterval, 0.5, accuracy: 1e-9)
        let zero = Duration.zero
        XCTAssertEqual(zero.timeInterval, 0.0, accuracy: 1e-9)
    }
}
