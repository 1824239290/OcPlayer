#if os(macOS)
import AppKit
import XCTest
@testable import OcPlayer

@MainActor
final class FullscreenToolbarBackgroundTests: XCTestCase {
    private func fixture() throws -> (NSWindow, FullscreenToolbarBackgroundView, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "fullscreen-background-test")
        let bridge = FullscreenToolbarBackgroundView(frame: .zero)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.addSubview(bridge)
        func background(in view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "NSTitlebarBackgroundView" { return view }
            return view.subviews.lazy.compactMap { background(in: $0) }.first
        }
        guard let frameView = contentView.superview, let titlebarBackground = background(in: frameView) else {
            bridge.stopObserving()
            throw XCTSkip("This AppKit version does not provide the supported titlebar background view")
        }
        return (window, bridge, titlebarBackground)
    }

    func testBackgroundStaysHiddenWhileMigratingBeforeHelperHasParent() throws {
        let (window, bridge, background) = try fixture()
        defer { bridge.stopObserving(); window.close() }
        background.isHidden = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)

        // AppKit moves this same view, then unhides it before the helper window
        // has a parent. A notification or next-run-loop repair is already late.
        let detachedTitlebar = NSView()
        detachedTitlebar.addSubview(background)
        XCTAssertNil(background.window)
        background.isHidden = false
        XCTAssertTrue(background.isHidden, "The reset must be corrected synchronously before drawing")

        bridge.stopObserving()
        XCTAssertFalse(background.isHidden, "Dismantle restores the system's requested full screen state")
    }

    func testExitReleasesObservationAndKeepsWindowedBackgroundState() throws {
        let (window, bridge, background) = try fixture()
        defer { bridge.stopObserving(); window.close() }
        background.isHidden = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        background.isHidden = false
        XCTAssertTrue(background.isHidden)

        // AppKit restores the transparent windowed titlebar before didExit.
        background.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertTrue(background.isHidden)
        background.isHidden = false
        XCTAssertFalse(background.isHidden, "Windowed updates must no longer be overridden")
    }

    func testAnotherWindowsFullscreenNotificationDoesNotPrepareThisTitlebar() throws {
        let (window, bridge, background) = try fixture()
        defer { bridge.stopObserving(); window.close() }
        let otherWindow = NSWindow()
        background.isHidden = false
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: otherWindow)
        XCTAssertFalse(background.isHidden)
    }
}
#endif
