import Foundation
import SwiftUI

@main
enum Entry {
    static func main() {
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
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(state: state)
        } label: {
            Image(systemName: state.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuBarExtraStyle(.window)
    }
}
