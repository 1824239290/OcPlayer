import XCTest
@testable import DiagnosticsKit

final class HTTPClientTests: XCTestCase {
    // MARK: - RetryPolicy 退避

    func testBackoffIsExponentialWithJitter() {
        let policy = RetryPolicy(attempts: 4, base: 2, jitter: 1.0...1.0)  // 钉死抖动便于断言
        // base^(n-1)：第 1 次重试等 1s，第 2 次 2s，第 3 次 4s。
        XCTAssertEqual(policy.backoffNanoseconds(attempt: 1), 1_000_000_000)
        XCTAssertEqual(policy.backoffNanoseconds(attempt: 2), 2_000_000_000)
        XCTAssertEqual(policy.backoffNanoseconds(attempt: 3), 4_000_000_000)
    }

    func testRetryAfterDominatesAndIsCapped() {
        let policy = RetryPolicy(attempts: 3)
        // 服务端说 5s → 用 5s（不带抖动）。
        XCTAssertEqual(policy.backoffNanoseconds(attempt: 1, retryAfter: 5), 5_000_000_000)
        // 服务端乱给大数 → 封顶 60s，不把调用挂死。
        XCTAssertEqual(policy.backoffNanoseconds(attempt: 1, retryAfter: 9999), 60_000_000_000)
    }

    // MARK: - run() 语义

    private struct Transient: Error {}

    func testRunSucceedsAfterTransientFailures() async throws {
        let policy = RetryPolicy(attempts: 3, base: 0, jitter: 1.0...1.0)  // 0 等待
        var attempts = 0
        let value = try await policy.run {
            attempts += 1
            if attempts < 3 { throw Transient() }
            return 42
        } shouldRetry: { $0 is Transient }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
    }

    func testRunStopsOnNonRetryableError() async {
        let policy = RetryPolicy(attempts: 5, base: 0, jitter: 1.0...1.0)
        var attempts = 0
        struct Fatal: Error {}
        do {
            _ = try await policy.run { () async throws -> Int in
                attempts += 1
                throw Fatal()
            } shouldRetry: { $0 is Transient }
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error is Fatal)
        }
        XCTAssertEqual(attempts, 1)  // 不可重试：一次就抛
    }

    func testRunDoesNotRetryCancellation() async {
        let policy = RetryPolicy(attempts: 5, base: 0, jitter: 1.0...1.0)
        var attempts = 0
        do {
            _ = try await policy.run { () async throws -> Int in
                attempts += 1
                throw CancellationError()
            } shouldRetry: { _ in true }
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempts, 1)
    }

    func testRunExhaustsAttemptsAndThrowsLastError() async {
        let policy = RetryPolicy(attempts: 2, base: 0, jitter: 1.0...1.0)
        var attempts = 0
        do {
            _ = try await policy.run { () async throws -> Int in
                attempts += 1
                throw Transient()
            } shouldRetry: { $0 is Transient }
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error is Transient)
        }
        XCTAssertEqual(attempts, 2)
    }
}
