import BangumiKit
import MoviePilotKit
import XCTest
@testable import OcPlayer

@MainActor
final class MyDashboardModelTests: XCTestCase {
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Int, Error>?
        func fetch() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    private func waitForRequest(_ gate: Gate) async throws {
        for _ in 0..<100 {
            if gate.continuation != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func testAccountSwitchRejectsLateResultAndStartsNewLoad() async throws {
        let source = MyDashboardSource<Int>()
        let gate = Gate()
        var scope: String? = "account-a"
        let old = Task { await source.load(scope: "account-a", currentScope: { scope }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        scope = "account-b"
        await source.load(scope: scope, currentScope: { scope }, fetch: { 2 })
        gate.continuation?.resume(returning: 1)
        await old.value
        XCTAssertEqual(source.snapshot(for: "account-b"), 2)
        XCTAssertNil(source.snapshot(for: "account-a"))
        XCTAssertFalse(source.isLoading)
    }

    func testSignOutClearsSnapshotAndRejectsInFlightResponse() async throws {
        let source = MyDashboardSource<Int>()
        let gate = Gate()
        var scope: String? = "account"
        let task = Task { await source.load(scope: scope, currentScope: { scope }, fetch: gate.fetch) }
        try await waitForRequest(gate)
        scope = nil
        await source.load(scope: nil, currentScope: { scope }, fetch: { 9 })
        gate.continuation?.resume(returning: 1)
        await task.value
        XCTAssertNil(source.value)
        XCTAssertNil(source.scope)
        XCTAssertNil(source.error)
        XCTAssertFalse(source.isLoading)
    }

    func testScopeChangeHidesSnapshotBeforeReplacementLoad() async {
        let source = MyDashboardSource<Int>()
        await source.load(scope: "a", currentScope: { "a" }, fetch: { 1 })
        XCTAssertNil(source.snapshot(for: "b"))
        XCTAssertNil(source.snapshot(for: nil))
    }

    func testFailedRefreshRetainsCachedDataAndCanRecover() async {
        let source = MyDashboardSource<Int>()
        await source.load(scope: "a", currentScope: { "a" }, fetch: { 1 })
        await source.load(scope: "a", currentScope: { "a" }, fetch: { throw MoviePilotError.request("offline") })
        XCTAssertEqual(source.value, 1)
        XCTAssertNotNil(source.error)
        await source.load(scope: "a", currentScope: { "a" }, fetch: { 2 })
        XCTAssertEqual(source.value, 2)
        XCTAssertNil(source.error)
    }

    func testCancellationIsNotDisplayedAsFailure() async {
        let source = MyDashboardSource<Int>()
        await source.load(scope: "a", currentScope: { "a" }, fetch: { 1 })
        await source.load(scope: "a", currentScope: { "a" }, fetch: { throw URLError(.cancelled) })
        XCTAssertEqual(source.value, 1)
        XCTAssertNil(source.error)
        XCTAssertFalse(source.isLoading)
    }

    func testOneSourceFailureDoesNotEraseAnotherSource() async {
        let model = MyDashboardModel()
        await model.bangumi.load(scope: "b", currentScope: { "b" }, fetch: { MyBangumiOverview(counts: [.doing: 3]) })
        await model.subscriptions.load(scope: "m", currentScope: { "m" }, fetch: { throw MoviePilotError.request("offline") })
        XCTAssertEqual(model.bangumi.value?.counts[.doing], 3)
        XCTAssertNotNil(model.subscriptions.error)
    }

    func testResourcesLinkOnlyByExplicitBangumiID() {
        let sameTitle = MPSubscribe(raw: ["id": .number(1), "name": .string("同名作品")])
        let correct = MPSubscribe(raw: ["id": .number(2), "bangumiid": .number(42), "total_episode": .number(12), "lack_episode": .number(3)])
        let wrong = MPSubscribe(raw: ["id": .number(3), "bangumiid": .number(43)])
        XCTAssertEqual(MyResourceLink.subscriptions(subjectID: 42, in: [sameTitle, correct, wrong]), [correct])
        XCTAssertNil(MyResourceLink.summary(subjectID: 99, in: [sameTitle, correct]))
        XCTAssertEqual(MyResourceLink.missingEpisodes(in: [correct]), 3)
    }

    func testMultipleSubscriptionsDoNotPretendToBeOneSeasonProgress() {
        let items = [1, 2].map { MPSubscribe(raw: ["id": .number(Double($0)), "bangumiid": .number(42)]) }
        XCTAssertEqual(MyResourceLink.summary(subjectID: 42, in: items), "已关联 2 个订阅")
    }

    func testChapterManagementUsesPersonalNavigationStack() async {
        let app = AppModel()
        app.setCompact(true)
        app.selectedSection = .my
        app.openBangumiProgress()
        #if os(macOS)
        try? await Task.sleep(for: .milliseconds(700))
        #endif
        XCTAssertEqual(app.navPath(for: .my), [.bangumiProgress])
        XCTAssertTrue(app.navPath(for: .home).isEmpty)
    }

    func testWishEntryOpensWishCollectionInPersonalStack() async {
        let app = AppModel()
        app.setCompact(true)
        app.selectedSection = .my
        app.openBangumiCollectionList(.anime, collectionType: .wish)
        #if os(macOS)
        try? await Task.sleep(for: .milliseconds(700))
        #endif
        XCTAssertEqual(app.navPath(for: .my), [.bangumiCollectionList(.anime, collection: .wish)])
    }
}
