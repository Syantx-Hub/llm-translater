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

    init(state: AppState) {
        panel.contentView = NSHostingView(rootView: SubtitleOverlayView(state: state))
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

    /// Bottom 40% of the main screen, inset from the edges; subtitles sit at its bottom.
    private func layout() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let width = frame.width * 0.84
        panel.setFrame(
            NSRect(x: frame.midX - width / 2, y: frame.minY + frame.height * 0.04,
                   width: width, height: frame.height * 0.4),
            display: true)
    }
}
