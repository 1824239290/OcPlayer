import AppKit
import SwiftUI

/// AppKit moves the native toolbar into a child window in full screen. Its opaque
/// backstop covers the artwork even when SwiftUI hides the toolbar background.
/// Keep the toolbar and its hit testing, and disable only its background layers.
struct FullscreenToolbarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> FullscreenToolbarBackgroundView {
        FullscreenToolbarBackgroundView()
    }

    func updateNSView(_ view: FullscreenToolbarBackgroundView, context: Context) {
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: FullscreenToolbarBackgroundView, coordinator: ()) {
        view.stopObserving()
    }
}

final class FullscreenToolbarBackgroundView: NSView {
    @MainActor private final class BackgroundState {
        weak var view: NSView?
        var isHidden: Bool
        let windowedIsHidden: Bool?
        var observation: NSKeyValueObservation?
        var isApplyingHidden = false

        init(view: NSView, isWindowed: Bool) {
            self.view = view
            isHidden = view.isHidden
            windowedIsHidden = isWindowed ? view.isHidden : nil
        }

        func hide() {
            guard let view, !view.isHidden else { return }
            isApplyingHidden = true
            view.isHidden = true
            isApplyingHidden = false
        }
    }

    private weak var hostWindow: NSWindow?
    private weak var preparedContentView: NSView?
    private var originalBackstop: Bool?
    private var backgrounds: [BackgroundState] = []
    private var isEnteringFullscreen = false
    private var updateScheduled = false

    private static let notifications: [Notification.Name] = [
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didUpdateNotification,
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.willCloseNotification,
    ]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hostWindow !== window else { return }
        stopObserving()
        hostWindow = window
        guard hostWindow != nil else { return }
        for name in Self.notifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowStateChanged(_:)), name: name, object: nil)
        }
        scheduleUpdate()
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        guard let hostWindow, let changedWindow = notification.object as? NSWindow,
              changedWindow === hostWindow || changedWindow.parent === hostWindow
        else { return }

        if changedWindow === hostWindow {
            switch notification.name {
            case NSWindow.willEnterFullScreenNotification:
                isEnteringFullscreen = true
                // AppKit detaches the titlebar before attaching its full screen
                // window to the host. Follow the existing background before that
                // migration; waiting for childWindows misses the whole animation.
                if let frameView = hostWindow.contentView?.superview {
                    prepareBackgrounds(in: frameView, isWindowed: true)
                }
                updateBackground()
            case NSWindow.didEnterFullScreenNotification:
                isEnteringFullscreen = false
            case NSWindow.didExitFullScreenNotification:
                isEnteringFullscreen = false
                restoreBackground(isWindowed: true)
            case NSWindow.willCloseNotification:
                stopObserving()
                return
            default:
                break
            }
        }
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard hostWindow != nil, !updateScheduled else { return }
        updateScheduled = true
        // Toolbar creation and replacement finish after the SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateBackground()
        }
    }

    private func updateBackground() {
        guard let hostWindow,
              isEnteringFullscreen || hostWindow.styleMask.contains(.fullScreen)
        else { return }

        guard let toolbarWindow = NSApp.windows.first(where: {
            guard NSStringFromClass(type(of: $0)) == "NSToolbarFullScreenWindow" else { return false }
            if $0.parent === hostWindow { return true }
            guard let contentView = $0.contentView else { return false }
            // During the animation parent is nil. Ownership is still unambiguous:
            // this window contains the titlebar background taken from our host.
            return Self.titlebarBackgrounds(in: contentView).contains { candidate in
                backgrounds.contains { $0.view === candidate }
            }
        }), let contentView = toolbarWindow.contentView,
              NSStringFromClass(type(of: contentView)) == "NSToolbarFullScreenContentView"
        else { return }

        if preparedContentView !== contentView {
            restoreBackstop()
            preparedContentView = contentView
        }

        // AppKit's titlebar background remains visible in the full screen child
        // even with toolbarBackgroundVisibility(.hidden). It is a sibling of the
        // toolbar controls; hiding this view leaves their glass and input intact.
        prepareBackgrounds(in: contentView)

        // Some AppKit configurations also draw an opaque content backstop.
        // This private property is optional; require both accessors before KVC.
        if contentView.responds(to: NSSelectorFromString("needsOpaqueBackstop")),
           contentView.responds(to: NSSelectorFromString("setNeedsOpaqueBackstop:")),
           let backstop = contentView.value(forKey: "needsOpaqueBackstop") as? Bool {
            if originalBackstop == nil { originalBackstop = backstop }
            if backstop {
                contentView.setValue(false, forKey: "needsOpaqueBackstop")
                contentView.needsDisplay = true
            }
        }
    }

    private func prepareBackgrounds(in view: NSView, isWindowed: Bool = false) {
        backgrounds.removeAll { $0.view == nil }
        for background in Self.titlebarBackgrounds(in: view) {
            if !backgrounds.contains(where: { $0.view === background }) {
                let state = BackgroundState(view: background, isWindowed: isWindowed)
                // The same background view is moved into the helper window, and
                // AppKit unhides it while building the animation. Re-hide it in
                // that setter's KVO callback, before a colored frame is committed.
                state.observation = background.observe(\.isHidden, options: [.new]) { [weak state] _, change in
                    MainActor.assumeIsolated {
                        guard let state, !state.isApplyingHidden, let isHidden = change.newValue else { return }
                        // Preserve AppKit's latest requested state for exit or
                        // dismantle; our own corrective writes are excluded.
                        state.isHidden = isHidden
                        state.hide()
                    }
                }
                backgrounds.append(state)
            }
            backgrounds.first { $0.view === background }?.hide()
        }
    }

    private static func titlebarBackgrounds(in view: NSView) -> [NSView] {
        if NSStringFromClass(type(of: view)) == "NSTitlebarBackgroundView" { return [view] }
        return view.subviews.flatMap { titlebarBackgrounds(in: $0) }
    }

    private func restoreBackground(isWindowed: Bool = false) {
        for state in backgrounds { state.observation?.invalidate() }
        for state in backgrounds {
            // Full screen asks to unhide the background. Do not replay that
            // request after AppKit has moved it back to the transparent titlebar.
            let visibility = isWindowed ? state.windowedIsHidden : Optional(state.isHidden)
            if let visibility { state.view?.isHidden = visibility }
        }
        backgrounds.removeAll()
        restoreBackstop()
    }

    private func restoreBackstop() {
        if let preparedContentView, let originalBackstop {
            preparedContentView.setValue(originalBackstop, forKey: "needsOpaqueBackstop")
            preparedContentView.needsDisplay = true
        }
        preparedContentView = nil
        originalBackstop = nil
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        restoreBackground()
        hostWindow = nil
        isEnteringFullscreen = false
    }
}
