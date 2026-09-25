import Foundation
import SwiftUI

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(into: CommandLine.arguments[index + 1]) }
            exit(0)
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
    @StateObject private var models: ModelStore
    @StateObject private var state: AppState

    init() {
        let models = ModelStore()
        _models = StateObject(wrappedValue: models)
        _state = StateObject(wrappedValue: AppState(models: models))
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(state: state, models: models)
        } label: {
            MenuBarIcon(running: state.isRunning, needsSetup: models.needsSetup)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Subtitler", id: "welcome") {
            WelcomeWindow(models: models, state: state)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Models", id: "models") {
            ModelsView(store: models)
        }
        .defaultSize(width: 700, height: 760)
    }
}

/// The menu bar label is created at launch, so it also opens setup on first run.
private struct MenuBarIcon: View {
    let running: Bool
    let needsSetup: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: running ? "captions.bubble.fill" : "captions.bubble")
            .task {
                guard needsSetup else { return }
                openWindow(id: "welcome")
                NSApp.activate(ignoringOtherApps: true)
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
