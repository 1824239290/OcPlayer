import CoreModel
import Foundation
import JellyfinKit
import XCTest

@testable import OcPlayer

@MainActor
final class QuickConnectOptInTests: XCTestCase {
    func testPairingStartsOnRequestAndCollapseCancelsWithoutShowingTimeout() async throws {
        let app = AppModel()
        let session = PairingSession(kind: .jellyfin)
        app.phase = .onboarding
        app.loginSession = session
        await Task.yield()
        XCTAssertEqual(session.subscriptionCount, 0)
        XCTAssertNil(app.quickConnectCode)

        app.startQuickConnect()
        session.continuation.yield(.polling("123456"))
        for _ in 0..<100 where app.quickConnectCode == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.subscriptionCount, 1)
        XCTAssertEqual(app.quickConnectCode, "123456")

        let pairingTask = app.quickConnectTask
        app.stopQuickConnect()
        XCTAssertNil(app.quickConnectTask)
        // A cancelled stream can end normally. It must not publish a timeout after collapse.
        session.continuation.finish()
        await pairingTask?.value
        XCTAssertNil(app.quickConnectCode)
        XCTAssertNil(app.quickConnectError)
        XCTAssertNotNil(app.loginSession)
    }

    func testEmbyNeverRequestsPairing() async {
        let app = AppModel()
        let session = PairingSession(kind: .emby)
        app.phase = .onboarding
        app.loginSession = session
        app.startQuickConnect()
        await Task.yield()
        XCTAssertEqual(session.subscriptionCount, 0)
        XCTAssertNil(app.quickConnectTask)
    }

    func testImmediateCollapseDoesNotRequestPairingCode() async {
        let app = AppModel()
        let session = PairingSession(kind: .jellyfin)
        app.phase = .onboarding
        app.loginSession = session

        app.startQuickConnect()
        let pairingTask = app.quickConnectTask
        app.stopQuickConnect()
        await pairingTask?.value

        XCTAssertEqual(session.subscriptionCount, 0)
        XCTAssertNil(app.quickConnectTask)
        XCTAssertNil(app.quickConnectCode)
        XCTAssertNil(app.quickConnectError)
    }

    func testPairingDoesNotStartAfterLeavingOnboarding() {
        let app = AppModel()
        let session = PairingSession(kind: .jellyfin)
        app.loginSession = session
        app.phase = .ready

        app.startQuickConnect()

        XCTAssertEqual(session.subscriptionCount, 0)
        XCTAssertNil(app.quickConnectTask)
    }
}

private final class PairingSession: ServerLoginSession, @unchecked Sendable {
    let kind: ServerKind
    let baseURL = URL(string: "https://cinema.example.test")!
    let serverName = "Test cinema"
    let serverID: String? = "test-cinema"
    let serverVersion: String? = "10.11"
    var supportsQuickConnect: Bool { kind == .jellyfin }
    private let lock = NSLock()
    private var subscriptions = 0
    private let stream: AsyncThrowingStream<QuickConnectEvent, Error>
    let continuation: AsyncThrowingStream<QuickConnectEvent, Error>.Continuation

    init(kind: ServerKind) {
        self.kind = kind
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    var subscriptionCount: Int { lock.withLock { subscriptions } }
    var quickConnectEvents: AsyncThrowingStream<QuickConnectEvent, Error> {
        lock.withLock { subscriptions += 1 }
        return stream
    }
    func signIn(username: String, password: String) async throws -> LoginResult { throw CocoaError(.userCancelled) }
    func signIn(quickConnectSecret: String) async throws -> LoginResult { throw CocoaError(.userCancelled) }
    func finish(_ result: LoginResult, store: ServerStore) throws -> any MediaServer { throw CocoaError(.userCancelled) }
}
