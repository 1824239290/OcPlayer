import MoviePilotKit
import XCTest
@testable import OcPlayer

@MainActor
final class MoviePilotSubscriptionLoaderTests: XCTestCase {
    @MainActor
    private final class ResponseGate {
        var continuation: CheckedContinuation<[MPSubscribe], Error>?
        var calls = 0
        func fetch() async throws -> [MPSubscribe] {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: Result<[MPSubscribe], Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func waitForRequest(_ gate: ResponseGate) async throws {
        for _ in 0..<100 {
            if gate.continuation != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Subscription request did not start")
        throw CancellationError()
    }

    private func items(_ id: Int) -> [MPSubscribe] {
        [MPSubscribe(raw: ["id": .number(Double(id))])]
    }

    func testSwitchStartsNewRequestAndOldCancellationCannotFinishIt() async throws {
        let loader = MoviePilotSubscriptionLoader()
        let a = ResponseGate(), b = ResponseGate()
        var revision: UInt64 = 1
        let old = Task { await loader.load(revision: 1, currentRevision: { revision }, fetch: a.fetch) }
        try await waitForRequest(a)
        old.cancel()
        revision = 2
        loader.reset() // Same reset used by the retained tab on rebinding.
        let new = Task { await loader.load(revision: 2, currentRevision: { revision }, fetch: b.fetch) }
        defer { a.finish(.failure(CancellationError())); b.finish(.failure(CancellationError())) }
        try await waitForRequest(b)
        a.finish(.failure(CancellationError()))
        await old.value
        XCTAssertTrue(loader.isLoading, "A must not clear B's loading state")
        XCTAssertNil(loader.error)
        b.finish(.success(items(2)))
        await new.value
        XCTAssertEqual(loader.items, items(2))
        XCTAssertFalse(loader.isLoading)
    }

    func testChangedRevisionDiscardsLateSuccessBeforeNewTabTaskRuns() async throws {
        let loader = MoviePilotSubscriptionLoader()
        let gate = ResponseGate()
        var revision: UInt64 = 1
        let old = Task { await loader.load(revision: 1, currentRevision: { revision }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        revision = 2
        gate.finish(.success(items(1)))
        await old.value
        XCTAssertTrue(loader.items.isEmpty)
        await loader.load(revision: 2, currentRevision: { revision }, fetch: { self.items(2) })
        XCTAssertEqual(loader.items, items(2))
    }

    func testLateOldFailureCannotReplaceNewSessionError() async throws {
        let loader = MoviePilotSubscriptionLoader()
        let gate = ResponseGate()
        var revision: UInt64 = 1
        let old = Task { await loader.load(revision: 1, currentRevision: { revision }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        revision = 2
        await loader.load(revision: 2, currentRevision: { revision }, fetch: {
            throw MoviePilotError.request("B failure")
        })
        gate.finish(.failure(MoviePilotError.request("A failure")))
        await old.value
        guard case .request("B failure")? = loader.error else {
            return XCTFail("Must retain B's error")
        }
    }

    func testCancelledRefreshPreservesItemsAndAllowsRetry() async {
        let loader = MoviePilotSubscriptionLoader()
        await loader.load(revision: 1, currentRevision: { 1 }, fetch: { self.items(1) })
        await loader.load(revision: 1, currentRevision: { 1 }, fetch: { throw URLError(.cancelled) })
        XCTAssertEqual(loader.items, items(1))
        XCTAssertNil(loader.error)
        XCTAssertFalse(loader.isLoading)
        await loader.load(revision: 1, currentRevision: { 1 }, fetch: { self.items(2) })
        XCTAssertEqual(loader.items, items(2))
    }

    func testSameRevisionDeduplicatesConcurrentLoads() async throws {
        let loader = MoviePilotSubscriptionLoader()
        let gate = ResponseGate()
        let first = Task { await loader.load(revision: 1, currentRevision: { 1 }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        await loader.load(revision: 1, currentRevision: { 1 }, fetch: gate.fetch)
        XCTAssertEqual(gate.calls, 1)
        gate.finish(.success(items(1)))
        await first.value
    }

    func testResetAllowsSameRevisionReloadAndRejectsOldSuccess() async throws {
        let loader = MoviePilotSubscriptionLoader()
        let gate = ResponseGate()
        let old = Task { await loader.load(revision: 1, currentRevision: { 1 }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        loader.reset()
        await loader.load(revision: 1, currentRevision: { 1 }, fetch: { self.items(2) })
        gate.finish(.success(items(1)))
        await old.value
        XCTAssertEqual(loader.items, items(2))
        XCTAssertNil(loader.error)
        XCTAssertFalse(loader.isLoading)
    }
}
