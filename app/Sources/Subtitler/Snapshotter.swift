import AppKit
import SwiftUI

/// Dev tool: renders the app's windows to PNGs (light and dark) without showing them or
/// needing Screen Recording, for reviewing the UI and README screenshots.
///
///   Subtitler --snapshot DIR
@MainActor
enum Snapshotter {
    static func run(into directory: String) {
        _ = NSApplication.shared
        let models = ModelStore()
        let style = CaptionStyle()
        let state = AppState(models: models, style: style)
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var views: [(String, AnyView, NSSize)] = [
            ("models", AnyView(ModelsView(store: models)), NSSize(width: 700, height: 1180)),
            ("panel", AnyView(ControlPanel(state: state, models: models)), NSSize(width: 360, height: 520)),
            ("captions", AnyView(CaptionsView(state: state, style: style)), NSSize(width: 900, height: 700)),
            ("subtitles", AnyView(SubtitleFileView(job: SubtitleJob(), state: state, models: models)), NSSize(width: 520, height: 560)),
            ("overlay", AnyView(SubtitleOverlayView(state: state, style: style).background(Color.gray)), NSSize(width: 1000, height: 320)),
        ]
        for step in WelcomeView.Step.allCases {
            views.append(("welcome-\(step.rawValue)",
                          AnyView(WelcomeView(store: models, state: state, initialStep: step) {}),
                          NSSize(width: 640, height: 660)))
        }
        state.previewLines()

        for (name, view, size) in views {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = out.appendingPathComponent("\(name)-\(suffix).png")
                render(view, size: size, appearance: NSAppearance(named: appearance)!, to: url)
                print(url.path)
            }
        }
    }

    private static func render(_ view: AnyView, size: NSSize, appearance: NSAppearance, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
