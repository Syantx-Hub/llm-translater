import Foundation
import SwiftUI

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(into: CommandLine.arguments[index + 1]) }
            exit(0)
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

    init() {
        let models = ModelStore()
        let style = CaptionStyle()
        _models = StateObject(wrappedValue: models)
        _style = StateObject(wrappedValue: style)
        _state = StateObject(wrappedValue: AppState(models: models, style: style))
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(state: state, models: models)
        } label: {
            MenuBarIcon(running: state.isRunning, needsSetup: models.needsSetup)
        }
        .menuBarExtraStyle(.window)

        Window("Subtitler", id: "main") {
            ControlPanel(state: state, models: models)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Subtitler", id: "welcome") {
            WelcomeWindow(models: models, state: state)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Captions", id: "captions") {
            CaptionsView(state: state, style: style)
        }
        .windowResizability(.contentSize)

        Window("Models", id: "models") {
            ModelsView(store: models)
        }
        .defaultSize(width: 700, height: 760)
    }
}

/// Opens SwiftUI windows from outside a view (the app delegate). SwiftUI only hands out
/// `openWindow` inside views, so the menu bar label, which exists from launch, registers it.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openWindow: OpenWindowAction?

    func show(_ id: String) {
        openWindow?(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the app again (Spotlight, Finder, `open`) shows its window. A menu bar
    /// icon alone is easy to miss, especially behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { WindowRouter.shared.show("main") }
        return true
    }
}

private struct MenuBarIcon: View {
    let running: Bool
    let needsSetup: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: running ? "captions.bubble.fill" : "captions.bubble")
            .task {
                WindowRouter.shared.openWindow = openWindow
                WindowRouter.shared.show(needsSetup ? "welcome" : "main")
            }
    }
}

private struct WelcomeWindow: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WelcomeView(store: models, state: state) { dismissWindow(id: "welcome") }
    }
}
