import AppKit
import SwiftUI

/// A transparent, click-through panel that floats above everything, including
/// full-screen video, on every Space.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let panel = OverlayPanel()
    private var screenObserver: NSObjectProtocol?

    init(state: AppState, style: CaptionStyle) {
        panel.contentView = NSHostingView(rootView: SubtitleOverlayView(state: state, style: style))
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Covers the whole main screen; CaptionLayer positions the text inside it, so style
    /// changes (position, width, offset) apply without moving the window.
    private func layout() {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
    }
}
