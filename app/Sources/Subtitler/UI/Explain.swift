import SwiftUI

// Pieces every window uses to say what a feature is for, where it is used.

/// What each way of using Subtitler is for, in the viewer's words.
extension CaptionMode {
    var symbol: String {
        switch self {
        case .translate: "character.bubble"
        case .transcribe: "text.bubble"
        case .synced: "doc.text.magnifyingglass"
        }
    }

    /// One line under the mode's name.
    var purpose: String {
        switch self {
        case .translate: "Translates whatever is playing, as it's said."
        case .transcribe: "Shows the words as they're spoken, in the same language."
        case .synced: "Shows the film's own subtitles, translated and exactly on time."
        }
    }

    /// When to pick it.
    var bestFor: String {
        switch self {
        case .translate: "Best for videos without subtitles: YouTube, live streams, calls."
        case .transcribe: "Best for following along, or learning a language."
        case .synced: "Best for films and series that have subtitles in the spoken language."
        }
    }

    /// Why Subtitle file mode asks for a file at all.
    static let whySubtitleFile = [
        "Live translation can only begin once a sentence is finished, so it's always about a second behind the actor, and it can mishear words.",
        "A subtitle file already has every line, written by people, each with its exact time. Subtitler only listens to find where you are in the film.",
        "Then it shows the file's lines, translated, at their own time: with the actor, not after, and never misheard.",
        "The file has to be in the language being spoken, because Subtitler finds its place by matching what it hears to the file's words.",
    ]

    /// "How this works", step by step.
    var steps: [String] {
        switch self {
        case .translate:
            [
                "Play the video, then press Start.",
                "Each sentence appears in your language once it's finished, about a second after it's said.",
                "Everything runs on this Mac unless you choose a cloud translator.",
            ]
        case .transcribe:
            [
                "Play the video, then press Start.",
                "Words appear while they're spoken and settle into a line when the sentence ends.",
            ]
        case .synced:
            [
                "Choose the subtitles for what you're watching (or find them online), in the language being spoken.",
                "Play the video and press Start. Subtitler listens for a clear line of dialogue to find its place.",
                "From then on, each line shows translated at the file's own time, with the actor, not after.",
                "Pausing and skipping are followed. If lines are a little early or late, nudge Timing.",
            ]
        }
    }
}

/// A labelled control with its label in a fixed column, so every popup in a panel starts
/// at the same edge (the grouped-form look, in a panel too narrow for a Form).
struct FieldRow<Control: View>: View {
    static var labelWidth: CGFloat { 118 }
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: Self.labelWidth, alignment: .leading)
                .lineLimit(1)
            control
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A footnote under a control: what it does, in one line.
struct HelpNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Details kept out of the way until asked for.
struct LearnMore<Content: View>: View {
    var title = "Learn more"
    @ViewBuilder var content: Content
    @StateObject private var open = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.value.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(title)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(open.value ? 90 : 0))
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.link)
            if open.value {
                VStack(alignment: .leading, spacing: 4) { content }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }
}

/// A notice line: calm by default, orange for things that cost time or money.
struct NoticeRow: View {
    enum Tone { case info, caution, done }
    let symbol: String
    let text: String
    var tone: Tone = .info

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tone == .caution ? Color.orange : tone == .done ? Color.green : Color.secondary)
        }
        .font(.caption)
        .foregroundStyle(tone == .caution ? Color.primary : Color.secondary)
    }
}

/// `@State` stand-in (the macro needs Xcode).
final class Flag: ObservableObject {
    @Published var value = false
}

/// Numbered steps, for "How this works" and the tour.
struct StepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor))
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Caption preview

/// Plays a few seconds of what a mode puts on screen, with the real caption style, so
/// choosing a mode shows what it does. Replays whenever the mode changes.
@MainActor
final class CaptionDemo: ObservableObject {
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var draft: DraftCaption?
    @Published private(set) var timecode: String?

    private var task: Task<Void, Never>?

    func play(mode: CaptionMode, language: String, reduceMotion: Bool) {
        task?.cancel()
        let samples = SampleCaptions.lines(language: language, translating: mode.translates)
        lines = []
        draft = nil
        timecode = mode == .synced ? "00:12:04" : nil
        guard !reduceMotion else {
            lines = [samples[0]]
            return
        }
        task = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let line = samples[index % samples.count]
                switch mode {
                case .transcribe:
                    // Words arrive while they're spoken, then settle into the line.
                    let words = line.original.split(separator: " ")
                    for count in 1...words.count {
                        self?.draft = DraftCaption(text: words.prefix(count).joined(separator: " "), isTranslation: false)
                        try? await Task.sleep(for: .milliseconds(260))
                    }
                    self?.draft = nil
                    self?.lines = [line]
                case .translate:
                    // The finished sentence, in one piece (the first one straight away).
                    if index > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                    self?.lines = [line]
                case .synced:
                    // On the file's own time: the clock runs, lines swap exactly on cue.
                    self?.timecode = String(format: "00:12:%02d", 4 + index * 3 % 50)
                    self?.lines = [line]
                }
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                if mode != .synced { self?.lines = [] }
                try? await Task.sleep(for: .milliseconds(300))
                index += 1
            }
        }
    }

    func stop() { task?.cancel() }
}

/// A small letterboxed video frame showing captions exactly as the overlay draws them.
struct CaptionPreview: View {
    @ObservedObject var style: CaptionStyle
    let mode: CaptionMode
    let language: String
    var height: CGFloat = 118
    @StateObject private var demo = CaptionDemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let screen = OverlayController.targetScreen?.frame.size ?? CGSize(width: 1440, height: 900)
            ZStack {
                // A dim scene, so the captions sit on something like a film.
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.36, green: 0.31, blue: 0.24).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.7, y: 0.35), startRadius: 4, endRadius: geometry.size.width * 0.45)
                CaptionLayer(style: style, lines: demo.lines, draft: demo.draft, language: language,
                             scale: geometry.size.width / screen.width * 1.6)
                if let timecode = demo.timecode {
                    Label(timecode, systemImage: "link")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .accessibilityLabel("In sync at \(timecode)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.25)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(mode.label) captions")
        .onAppear { demo.play(mode: mode, language: language, reduceMotion: reduceMotion) }
        .onDisappear { demo.stop() }
        .onChange(of: mode) { demo.play(mode: $0, language: language, reduceMotion: reduceMotion) }
        .onChange(of: language) { demo.play(mode: mode, language: $0, reduceMotion: reduceMotion) }
    }
}

// MARK: - Mode chooser

/// The three ways to use Subtitler, each saying what it's for.
struct ModeChooser: View {
    @Binding var mode: CaptionMode
    var showsBestFor = false

    var body: some View {
        VStack(spacing: 4) {
            ForEach(CaptionMode.allCases) { item in
                Button { mode = item } label: { row(item) }
                    .buttonStyle(.plain)
                    // The selected row is shown by its tint and checkmark; a focus ring
                    // around another row reads as a second selection.
                    .focusEffectDisabled()
                    .accessibilityAddTraits(item == mode ? .isSelected : [])
            }
        }
    }

    private func row(_ item: CaptionMode) -> some View {
        let selected = item == mode
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(.medium))
                Text(item.purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsBestFor {
                    Text(item.bestFor).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }
}
