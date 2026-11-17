import XCTest
@testable import AppDesignKit

private struct Row: Identifiable, Equatable {
    let id: Int
}

/// 可挂起的闸门：fetch 可在此阻塞，主测程随后手动放行。
/// 用它做确定性并发，避免 `async let` 在 @MainActor 上排队导致卡死。
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasEntered = false

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            continuation = c
            wasEntered = true
            lock.unlock()
        }
    }

    /// 阻塞直到至少一个有调用方进入 `wait()`（从而已让出主 actor）。
    func waitUntilEntered() async {
        while !wasEntered { await Task.yield() }
    }

    func release() {
        lock.lock()
        let c = continuation
        continuation = nil
        wasEntered = false
        lock.unlock()
        c?.resume()
    }
}

@MainActor
private final class PagedListLoaderTests: XCTestCase {
    /// @MainActor：与 loader 的 fetch 闭包同域，避免跨隔离域送 stub。
    @MainActor
    private final class Stub {
        var calls: [Int] = []
        var pages: [[Row]] = []
        var totals: [Int?] = []
        var error: Error?

        func fetch(_ offset: Int, _ limit: Int) async throws -> PagedListLoader<Row>.Page {
            calls.append(offset)
            if let error { throw error }
            let index = offset / limit
            return .init(
                items: index < pages.count ? pages[index] : [],
                total: index < totals.count ? totals[index] : nil
            )
        }
    }

    private struct SampleError: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func makeLoader(_ stub: Stub, pageSize: Int = 2) -> PagedListLoader<Row> {
        PagedListLoader<Row>(pageSize: pageSize) { offset, limit in
            try await stub.fetch(offset, limit)
        }
    }

    func testInitialLoadFillsItemsAndTotal() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)]]
        stub.totals = [5]
        let loader = makeLoader(stub)

        await loader.loadInitial()

        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 2)])
        XCTAssertEqual(loader.totalCount, 5)
        XCTAssertTrue(loader.hasMore)
        XCTAssertNil(loader.loadError)
        XCTAssertEqual(stub.calls, [0])
    }

    func testLoadMoreAppendsWithDedupe() async {
        let stub = Stub()
        // 第二页含一个与第一页重复的 id=2（同步窗口内本地库被改过的场景）。
        stub.pages = [[Row(id: 1), Row(id: 2)], [Row(id: 2), Row(id: 3)]]
        stub.totals = [3, 3]
        let loader = makeLoader(stub)

        await loader.loadInitial()
        await loader.loadMore()

        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 2), Row(id: 3)])
        XCTAssertFalse(loader.hasMore)
        XCTAssertEqual(stub.calls, [0, 2])
    }

    func testCursorAdvancesByRawRowsAcrossOverlappingAndDuplicatePages() async {
        let stub = Stub()
        stub.pages = [
            [Row(id: 1), Row(id: 2), Row(id: 2)],
            [Row(id: 2), Row(id: 3), Row(id: 3)],
            [Row(id: 4), Row(id: 5)],
        ]
        stub.totals = [8, 8, 8]
        let loader = makeLoader(stub, pageSize: 3)

        await loader.loadInitial()
        await loader.loadMore()
        await loader.loadMore()

        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 2), Row(id: 3), Row(id: 4), Row(id: 5)])
        XCTAssertFalse(loader.hasMore)
        XCTAssertEqual(stub.calls, [0, 3, 6])
    }

    func testRemovingLocalItemDoesNotMoveServerCursor() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)], [Row(id: 3), Row(id: 4)]]
        stub.totals = [4, 4]
        let loader = makeLoader(stub)

        await loader.loadInitial()
        loader.remove(id: 2)
        await loader.loadMore()

        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 3), Row(id: 4)])
        XCTAssertEqual(stub.calls, [0, 2])
    }

    func testFailedInitialReloadPreservesCursorForNextPage() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)], [Row(id: 3), Row(id: 4)]]
        stub.totals = [4, 4]
        let loader = makeLoader(stub)

        await loader.loadInitial()
        stub.error = SampleError()
        await loader.loadInitial()
        stub.error = nil
        await loader.loadMore()

        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 2), Row(id: 3), Row(id: 4)])
        XCTAssertEqual(stub.calls, [0, 0, 2])
    }

    func testHasMoreWithoutTotalFallsBackToFullPageHeuristic() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)], [Row(id: 3)]]  // 第二页不满 → 没有更多了
        let loader = makeLoader(stub)

        await loader.loadInitial()
        XCTAssertTrue(loader.hasMore)
        await loader.loadMore()
        XCTAssertFalse(loader.hasMore)
    }

    func testLoadMoreAfterEndIsNoop() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)], [Row(id: 3)]]
        stub.totals = [3, 3]
        let loader = makeLoader(stub)

        await loader.loadInitial()
        await loader.loadMore()   // 到底，hasMore 变 false
        let callsBefore = stub.calls.count
        await loader.loadMore()   // 再调应被 hasMore 挡掉，不发请求
        XCTAssertEqual(stub.calls.count, callsBefore)
    }

    func testReloadDoesNotAppendStaleLoadMoreResult() async {
        let gate = AsyncGate()
        let stub = Stub()
        stub.pages = [[Row(id: 1)], [Row(id: 9)]]
        stub.totals = [99, 99]
        var gateHeld = false
        let loader = PagedListLoader<Row>(pageSize: 1) { offset, limit in
            stub.calls.append(offset)
            if offset > 0, !gateHeld {
                gateHeld = true
                await gate.wait()   // 第一页翻页挂在闸上，让重取先进来
            }
            let index = offset / limit
            return .init(items: index < stub.pages.count ? stub.pages[index] : [], total: 99)
        }
        await loader.loadInitial()   // items = [1]

        let stale = Task { await loader.loadMore() }   // offset 1 → 停在闸上
        await gate.waitUntilEntered()
        await loader.loadInitial()   // 重取 → 换成新页结果
        gate.release()
        await stale.value

        // 旧翻页(9)被代次守卫丢弃，不能混进重取后的列表。
        XCTAssertEqual(loader.items, [Row(id: 1)])
        XCTAssertEqual(loader.totalCount, 99)
    }

    func testInitialLoadErrorIsSurfaced() async {
        let stub = Stub()
        stub.error = SampleError()
        let loader = makeLoader(stub)

        await loader.loadInitial()

        XCTAssertEqual(loader.loadError, "boom")
        XCTAssertTrue(loader.items.isEmpty)
    }

    func testLoadMoreErrorDoesNotClobberLoadedList() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)]]
        stub.totals = [10]
        let loader = makeLoader(stub)
        await loader.loadInitial()

        stub.error = SampleError()
        await loader.loadMore()

        // 翻页失败：列表内容保留，错误位不占用（留给下一次滚动重试）。
        XCTAssertEqual(loader.items, [Row(id: 1), Row(id: 2)])
        XCTAssertNil(loader.loadError)
        XCTAssertTrue(loader.hasMore)
    }

    func testReplaceAndRemove() async {
        let stub = Stub()
        stub.pages = [[Row(id: 1), Row(id: 2)]]
        let loader = makeLoader(stub)
        await loader.loadInitial()

        loader.replace(Row(id: 1))
        loader.remove(id: 2)

        XCTAssertEqual(loader.items, [Row(id: 1)])
    }

    func testCancellationErrorIsNotFailure() async {
        let loader = PagedListLoader<Row>(pageSize: 2) { _, _ in
            throw CancellationError()
        }
        await loader.loadInitial()
        XCTAssertNil(loader.loadError)
    }
}
