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
        // Never the real Keychain: a snapshot must not show whether keys exist.
        // Throwaway settings and a made-up key: a snapshot never changes the real app's
        // settings, and the Cloud section shows its masked "saved" state.
        let defaults = UserDefaults(suiteName: "com.syantxhub.subtitler.snapshot")!
        defaults.removePersistentDomain(forName: "com.syantxhub.subtitler.snapshot")
        defer { defaults.removePersistentDomain(forName: "com.syantxhub.subtitler.snapshot") }
        WelcomeView.recordsTour = false
        let models = ModelStore(defaults: defaults, secrets: MemorySecretStore(["openrouter": "sk-or-example-0000-1234"]))
        let style = CaptionStyle(defaults: defaults)
        let state = AppState(models: models, style: style, defaults: defaults)
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var views: [(String, AnyView, NSSize)] = [
            ("models", AnyView(ModelsView(store: models)), NSSize(width: 700, height: 2900)),
            ("panel", AnyView(ControlPanel(state: state, models: models, subtitleJob: SubtitleJob(), style: style)),
             NSSize(width: 360, height: 820)),
            ("captions", AnyView(CaptionsView(state: state, style: style)), NSSize(width: 900, height: 700)),
            ("subtitles", AnyView(SubtitleFileView(job: SubtitleJob(), state: state, models: models)), NSSize(width: 520, height: 560)),
            ("overlay", AnyView(SubtitleOverlayView(state: state, style: style).background(Color.gray)), NSSize(width: 1000, height: 320)),
        ]
        for step in WelcomeView.Step.allCases {
            views.append(("welcome-\(step.rawValue)",
                          AnyView(WelcomeView(store: models, state: state, style: style, initialStep: step) {}),
                          NSSize(width: 640, height: 680)))
        }
        state.previewLines()

        let startMode = state.mode
        for (name, view, size) in views {
            // The panel once per mode: each shows different settings.
            let modes: [CaptionMode?] = name == "panel" ? CaptionMode.allCases : [nil]
            for mode in modes {
                if let mode { state.mode = mode }
                let label = mode.map { "\(name)-\($0.rawValue)" } ?? name
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let url = out.appendingPathComponent("\(label)-\(suffix).png")
                    render(view, size: size, appearance: NSAppearance(named: appearance)!, to: url)
                    print(url.path)
                }
            }
        }
        state.mode = startMode

        // Cloud states: a live-mode warning, a whole-file estimate, and a cached file.
        let startTranslation = models.selectedTranslation
        models.selectCloud(.openRouter)
        state.mode = .translate
        renderBoth("panel-translate-cloud", AnyView(ControlPanel(state: state, models: models, subtitleJob: SubtitleJob(), style: style)),
                   NSSize(width: 360, height: 900), into: out)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitler-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let film = folder.appendingPathComponent("Parasite (2019).ko.srt")
        let cues = (0..<600).map { SubtitleCue(start: Double($0) * 4, end: Double($0) * 4 + 3, text: "대사 \($0 + 1)입니다.") }
        try? SubtitleFile.srt(cues).write(to: film, atomically: true, encoding: .utf8)
        state.loadSyncFile(film)
        state.mode = .synced
        renderBoth("panel-synced-cloud", AnyView(ControlPanel(state: state, models: models, subtitleJob: SubtitleJob(), style: style)),
                   NSSize(width: 360, height: 1000), into: out)
        let job = SubtitleJob()
        job.load(film)
        renderBoth("subtitles-cloud", AnyView(SubtitleFileView(job: job, state: state, models: models)),
                   NSSize(width: 520, height: 600), into: out)
        let translated = cues.map { SubtitleCue(start: $0.start, end: $0.end, text: "စကား") }
        try? SubtitleFile.srt(translated).write(to: SubtitleFile.translationURL(for: film, target: state.targetLanguage),
                                              atomically: true, encoding: .utf8)
        renderBoth("panel-synced-cached", AnyView(ControlPanel(state: state, models: models, subtitleJob: SubtitleJob(), style: style)),
                   NSSize(width: 360, height: 1000), into: out)
        try? FileManager.default.removeItem(at: folder)
        models.selectedTranslation = startTranslation
        state.mode = startMode
    }

    private static func renderBoth(_ name: String, _ view: AnyView, _ size: NSSize, into out: URL) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = out.appendingPathComponent("\(name)-\(suffix).png")
            render(view, size: size, appearance: NSAppearance(named: appearance)!, to: url)
            print(url.path)
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
