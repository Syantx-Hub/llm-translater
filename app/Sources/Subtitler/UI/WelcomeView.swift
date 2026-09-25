import CoreGraphics
import SwiftUI

/// First-run setup: the app ships without models, so walk people through picking a
/// speech model, a translation model and the audio permission.
struct WelcomeView: View {
    @ObservedObject var store: ModelStore
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    // @StateObject rather than @State: the SwiftUI macro plugin behind @State ships only
    // with Xcode, and this app builds with the Command Line Tools.
    @StateObject private var flow: Flow

    private var step: Step { flow.step }
    private var hasPermission: Bool { flow.hasPermission }

    final class Flow: ObservableObject {
        @Published var step: Step
        @Published var hasPermission = CGPreflightScreenCaptureAccess()

        init(step: Step) { self.step = step }
    }

    init(store: ModelStore, state: AppState, initialStep: Step = .welcome, onFinish: @escaping () -> Void) {
        self.store = store
        self.state = state
        self.onFinish = onFinish
        _flow = StateObject(wrappedValue: Flow(step: initialStep))
    }

    enum Step: Int, CaseIterable {
        case welcome, speech, translation, permission, done
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 32)
                .padding(.top, 28)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 640, height: 660)
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .speech: speech
        case .translation: translation
        case .permission: permission
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 8) {
                Text("Live subtitles for anything you watch").font(.title.weight(.semibold))
                Text("Subtitler listens to your Mac's audio and shows translated subtitles on top of any app — even full-screen video.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("lock.shield", "Private", "Runs entirely on this Mac. Nothing is uploaded.")
                feature("globe", "Burmese first", "Plus English, Korean, Japanese, Chinese, Thai and more.")
                feature("arrow.down.circle", "Pick your models", "Download only what you need; switch any time.")
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var speech: some View {
        stepLayout(
            title: "Choose a speech model",
            subtitle: "This turns what you hear into text. We've marked the best fit for your \(Hardware.chipName) with \(Hardware.ramGB) GB."
        ) {
            ForEach(ModelCatalog.speech) { ModelCard(model: $0, store: store, compact: true) }
        }
    }

    private var translation: some View {
        stepLayout(
            title: "Choose a translation model",
            subtitle: "This turns the text into your subtitle language. You can skip this and show the original text instead."
        ) {
            Picker("Subtitles in", selection: $state.targetLanguage) {
                ForEach(Languages.all) { Text($0.name).tag($0.code) }
            }
            .frame(maxWidth: 280)
            .padding(.bottom, 4)
            ForEach(ModelCatalog.translation) { ModelCard(model: $0, store: store, compact: true) }
        }
    }

    private var permission: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: hasPermission ? "checkmark.seal.fill" : "speaker.wave.2.circle")
                .font(.system(size: 52))
                .foregroundStyle(hasPermission ? Color.green : Color.accentColor)
            Text("Let Subtitler hear your Mac").font(.title2.weight(.semibold))
            Text("macOS lets apps hear system audio through the Screen Recording permission. Subtitler only uses the audio, never stores it, and it never leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if hasPermission {
                Label("Permission granted", systemImage: "checkmark").foregroundStyle(.green)
            } else {
                HStack {
                    Button("Allow…") {
                        flow.hasPermission = CGRequestScreenCaptureAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                Text("After allowing it in System Settings you may need to reopen Subtitler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            flow.hasPermission = CGPreflightScreenCaptureAccess()
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You're all set").font(.title.weight(.semibold))
            VStack(spacing: 6) {
                Text("Play any video, then click \(Image(systemName: "captions.bubble")) in the menu bar and press Start.")
                if isDownloading {
                    Text("Your models are still downloading; you can start once they finish.")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            stepDots
            Spacer()
            switch step {
            case .welcome:
                Button("Get started") { move(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .speech:
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSpeechChoice)
            case .translation:
                if hasTranslationChoice {
                    Button("Continue") { move(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") {
                        store.selectedTranslation = ModelStore.translationOff
                        move(1)
                    }
                }
            case .permission:
                Button(hasPermission ? "Continue" : "Later") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Finish") { onFinish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func stepLayout<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10, content: content)
                    .padding(.bottom, 12)
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .frame(width: 420, alignment: .leading)
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeOut(duration: 0.2)) { flow.step = next }
    }

    private func hasChoice(in models: [ModelInfo]) -> Bool {
        models.contains { store.isInstalled($0) || isDownloading($0) }
    }

    private var hasSpeechChoice: Bool { hasChoice(in: ModelCatalog.speech) }
    private var hasTranslationChoice: Bool { hasChoice(in: ModelCatalog.translation) }
    private var isDownloading: Bool { ModelCatalog.all.contains(where: isDownloading) }

    private func isDownloading(_ model: ModelInfo) -> Bool {
        if case .downloading = store.status(of: model) { true } else { false }
    }
}
