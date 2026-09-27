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
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(state: AppState, style: CaptionStyle) {
        panel.contentView = NSHostingView(rootView: SubtitleOverlayView(state: state, style: style))
        // Follow the video: re-pick the screen when displays change, when the user switches
        // Spaces (e.g. into a full-screen player) and when another app comes forward.
        let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(onlyIfVisible: true) }
        }
        observers = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification),
        ].map { center, name in (center, center.addObserver(forName: name, object: nil, queue: .main, using: relayout)) }
    }

    func show() {
        layout(onlyIfVisible: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The screen the person is most likely watching: the one with the pointer.
    static var targetScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// Covers the target screen below the camera housing (notch); CaptionLayer positions
    /// the text inside it, so style changes apply without moving the window.
    private func layout(onlyIfVisible: Bool) {
        guard !onlyIfVisible || panel.isVisible, let screen = Self.targetScreen else { return }
        var frame = screen.frame
        frame.size.height -= screen.safeAreaInsets.top
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}
