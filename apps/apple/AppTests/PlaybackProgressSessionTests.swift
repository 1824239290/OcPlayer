import CoreModel
import Foundation
import MetadataKit
@testable import OcPlayer
@testable import PlaybackKit
import XCTest

@MainActor
final class PlaybackProgressSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func readyApp() async -> AppModel {
        let app = AppModel()
        app.metadata.setup(directory: directory)
        _ = await app.metadata.waitUntilReady()
        return app
    }

    private func item(_ name: String = "original") -> MediaItem {
        MediaItem(id: "shared", name: name, kind: .movie,
                  playState: .init(played: false, percentage: 0, positionSeconds: 0))
    }

    private func prepare(_ app: AppModel, server: StubMediaServer, position: Int) async throws -> PlaybackController {
        server.itemResult = .success(item())
        app.server = server
        _ = try await app.metadata.refreshItem(itemID: "shared")
        let controller = PlaybackController()
        app.playback = controller
        app.nowPlayingItem = item()
        controller.state.apply(.durationChanged(.seconds(100)))
        controller.state.apply(.positionChanged(.seconds(position)))
        return controller
    }

    func testFinishThenSwitchWritesOnlyOriginalTenant() async throws {
        let app = await readyApp()
        let next = StubMediaServer(profileID: "b:user")
        next.itemResult = .success(item("next"))
        app.server = next
        _ = try await app.metadata.refreshItem(itemID: "shared")
        let original = StubMediaServer(profileID: "a:user")
        let controller = try await prepare(app, server: original, position: 42)
        let finish = app.finishReporting()
        // 同一主 actor 调用栈中切服，确保排队写回尚未执行。
        app.server = next
        await finish?.value
        let store = try XCTUnwrap(app.metadata.activeStore)
        let old = try await store.item("shared", tenant: TenantID(profile: original.profile))
        let new = try await store.item("shared", tenant: TenantID(profile: next.profile))
        XCTAssertEqual(old?.item.playState?.positionSeconds, 42)
        XCTAssertEqual(new?.item.playState?.positionSeconds, 0)
        _ = controller
    }

    func testSignOutPreservesLastProgressAndDoesNotReviveRepository() async throws {
        let app = await readyApp()
        let server = StubMediaServer()
        let controller = try await prepare(app, server: server, position: 42)
        app.signOut()
        let finish = app.finishReporting() // 重复收尾仍应等已排队写回。
        await finish?.value
        let store = try XCTUnwrap(app.metadata.activeStore)
        let cached = try await store.item("shared", tenant: TenantID(profile: server.profile))
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42)
        XCTAssertNil(app.metadata.repositoryIfReady)
        XCTAssertNil(app.server)
        _ = controller
    }

    func testRepeatedFinishDoesNotWriteSecondPosition() async throws {
        let app = await readyApp()
        let server = StubMediaServer()
        let controller = try await prepare(app, server: server, position: 42)
        let first = app.finishReporting()
        controller.state.apply(.positionChanged(.seconds(90)))
        let second = app.finishReporting()
        await second?.value
        await first?.value
        let store = try XCTUnwrap(app.metadata.activeStore)
        let cached = try await store.item("shared", tenant: TenantID(profile: server.profile))
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42)
    }

    func testSameTenantNewSessionWritesInOrder() async throws {
        let app = await readyApp()
        let server = StubMediaServer()
        let controller = try await prepare(app, server: server, position: 42)
        let first = app.finishReporting()
        app.server = StubMediaServer(profileID: server.profile.id)
        app.nowPlayingItem = item()
        controller.state.apply(.positionChanged(.seconds(60)))
        let second = app.finishReporting()
        await second?.value
        await first?.value
        let store = try XCTUnwrap(app.metadata.activeStore)
        let cached = try await store.item("shared", tenant: TenantID(profile: server.profile))
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 60)
    }
}
