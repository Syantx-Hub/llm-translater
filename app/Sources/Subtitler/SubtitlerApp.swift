import Foundation
import SwiftUI

@main
enum Entry {
    static func main() {
        // Writing to a crashed translation sidecar's stdin must return an error, not kill us.
        signal(SIGPIPE, SIG_IGN)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(into: CommandLine.arguments[index + 1]) }
            exit(0)
        }
        if CommandLine.arguments.contains("--search-subtitles") {
            Task.detached { exit(await SubtitleSearchRunner.run(arguments: CommandLine.arguments)) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--translate-subtitles") {
            Task.detached { exit(await SubtitleRunner.run(arguments: CommandLine.arguments)) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--audio-probe") {
            Task.detached { exit(await AudioProbe.run()) }
            dispatchMain()
        }
        guard CommandLine.arguments.contains("--file") else {
            SubtitlerApp.main()
            return
        }
        Task.detached {
            exit(await FileRunner.run(arguments: CommandLine.arguments))
        }
        dispatchMain()
    }
}

struct SubtitlerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var models: ModelStore
    @StateObject private var state: AppState
    @StateObject private var style: CaptionStyle
    @StateObject private var subtitleJob = SubtitleJob()
    @StateObject private var subtitleSearch = SubtitleSearch()

    init() {
        let models = ModelStore()
        let style = CaptionStyle()
        _models = StateObject(wrappedValue: models)
        _style = StateObject(wrappedValue: style)
        _state = StateObject(wrappedValue: AppState(models: models, style: style))
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(state: state, models: models, subtitleJob: subtitleJob, style: style)
        } label: {
            MenuBarIcon(running: state.isRunning, needsSetup: models.needsSetup)
        }
        .menuBarExtraStyle(.window)

        Window("Subtitler", id: "main") {
            ControlPanel(state: state, models: models, subtitleJob: subtitleJob, style: style)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Subtitler", id: "welcome") {
            WelcomeWindow(models: models, state: state, style: style)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Captions", id: "captions") {
            CaptionsView(state: state, style: style)
        }
        .windowResizability(.contentSize)

        Window("Find Subtitles", id: "find-subtitles") {
            SubtitleSearchView(search: subtitleSearch, state: state)
        }
        .windowResizability(.contentSize)

        Window("Translate Subtitles", id: "subtitles") {
            SubtitleFileView(job: subtitleJob, state: state, models: models)
        }
        .windowResizability(.contentSize)

        Window("Models", id: "models") {
            ModelsView(store: models)
        }
        .defaultSize(width: 700, height: ScreenFit.height(760))
    }
}

/// Opens SwiftUI windows from outside a view (the app delegate). SwiftUI only hands out
/// `openWindow` inside views, so the menu bar label, which exists from launch, registers it.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openWindow: OpenWindowAction?
    private var openedAtLaunch = false

    func show(_ id: String) {
        if let openWindow {
            openWindow(id: id)
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true && !($0 is NSPanel) }) {
            // Before the label registered: bring back a window SwiftUI already created.
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The label's task can run again if SwiftUI rebuilds the status item; only the first
    /// run opens a window.
    func showAtLaunch(_ id: String) {
        guard !openedAtLaunch else { return }
        openedAtLaunch = true
        show(id)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A menu bar app has no Dock icon and isn't in Cmd+Tab. While one of its windows is
    /// open (main, Models, Captions, …) it becomes a regular app, so Cmd+Tab can get back
    /// to it; when the last one closes it goes back to living in the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let closing = name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { Self.updateActivationPolicy(ignoring: closing) }
            }
        }
    }

    /// The `Window` scenes' ids.
    static let windowIDs = ["main", "welcome", "captions", "find-subtitles", "subtitles", "models"]

    @MainActor
    static func updateActivationPolicy(ignoring closing: NSWindow? = nil) {
        // Only the app's own windows count; the menu bar panel and the overlay never do, so
        // clicking the menu bar icon keeps the app out of the Dock.
        let hasWindow = NSApp.windows.contains { window in
            guard window !== closing, window.isVisible, let id = window.identifier?.rawValue else { return false }
            return Self.windowIDs.contains { id.contains($0) }
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Opening the app again (Spotlight, Finder, `open`) shows its window. A menu bar
    /// icon alone is easy to miss, especially behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { WindowRouter.shared.show("main") }
        return false // handled; don't let AppKit also reopen windows
    }
}

private struct MenuBarIcon: View {
    let running: Bool
    let needsSetup: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: running ? "captions.bubble.fill" : "captions.bubble")
            .accessibilityLabel(running ? "Subtitler, live" : needsSetup ? "Subtitler, needs setup" : "Subtitler")
            .task {
                WindowRouter.shared.openWindow = openWindow
                // Like other menu bar apps, launch quietly into the menu bar; only a first
                // run (or a new tour) opens a window. Opening the app again shows the panel.
                if needsSetup || !WelcomeView.hasSeenTour { WindowRouter.shared.showAtLaunch("welcome") }
            }
    }
}

private struct WelcomeWindow: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var state: AppState
    @ObservedObject var style: CaptionStyle
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WelcomeView(store: models, state: state, style: style) { dismissWindow(id: "welcome") }
    }
}
