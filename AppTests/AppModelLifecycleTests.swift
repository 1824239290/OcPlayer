import CoreModel
@testable import OcPlayer
import XCTest

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testSignOutClearsPresentedDetailAndPlayerSession() {
        let app = AppModel()
        app.phase = .ready
        app.presentedDetail = MediaItem(id: "series-1", name: "测试剧", kind: .series)
        app.presentedPlayer = PlaybackRequest(title: "ep", uri: "/tmp/a.mkv")
        app.playbackPreparation = .loading(title: "ep")
        app.path = [.detail(MediaItem(id: "m1", name: "电影", kind: .movie))]

        app.signOut()

        XCTAssertNil(app.presentedDetail)
        XCTAssertNil(app.presentedPlayer)
        XCTAssertNil(app.playbackPreparation)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
    }

    func testReconnectFlowClearsPresentedDetail() {
        let app = AppModel()
        app.phase = .ready
        app.presentedDetail = MediaItem(id: "series-2", name: "另一部", kind: .series)
        app.path = [.detail(MediaItem(id: "m2", name: "电影2", kind: .movie))]

        app.reconnectFlow()

        XCTAssertNil(app.presentedDetail)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
    }

    func testPresentLocalFileSetsPreparationWithoutTouchingHomeError() {
        let app = AppModel()
        app.phase = .onboarding
        app.home.error = nil

        let url = URL(fileURLWithPath: "/tmp/ocplayer-lifecycle-test.mkv")
        app.presentLocalFile(url)

        XCTAssertEqual(app.phase, .ready)
        XCTAssertNotNil(app.presentedPlayer)
        XCTAssertEqual(app.presentedPlayer?.uri, url.path)
        guard case .loading(let title) = app.playbackPreparation else {
            return XCTFail("local present must show preparation loading")
        }
        XCTAssertEqual(title, url.lastPathComponent)
        XCTAssertNil(app.home.error)
    }

    func testPlayerClosePolicyRejectsStaleDismissAfterNewRequest() {
        let oldID = UUID()
        let newID = UUID()
        XCTAssertTrue(PlayerClosePolicy.shouldDismiss(presentedID: oldID, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: newID, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: nil, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: oldID, closingID: nil))
    }
}
