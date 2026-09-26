import SwiftUI

/// "Translate with": the downloaded offline models next to the cloud engines that are set
/// up, and what each choice means for privacy.
struct TranslationEnginePicker: View {
    @ObservedObject var models: ModelStore
    /// Where the picker is used, which changes the advice under it.
    let mode: CaptionMode
    /// Inside a Form, which lays out its own label column.
    var inForm = false
    let openModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if inForm { picker } else { FieldRow("Translate with") { picker } }
            remark
        }
    }

    private var picker: some View {
        Picker("Translate with", selection: selection) {
                ForEach(ModelCatalog.translation.filter(models.isInstalled)) { model in
                    Text("\(model.name) · offline").tag(model.id)
                }
                if !models.configuredCloud.isEmpty { Divider() }
                ForEach(models.configuredCloud) { provider in
                    Text(cloudLabel(provider)).tag(ModelStore.cloudPrefix + provider.id)
                }
                if models.sidecarAvailable {
                    Divider()
                    ForEach(SidecarEngine.allCases) { Text($0.label).tag(ModelStore.sidecarPrefix + $0.rawValue) }
                }
                if !isListed { Text(models.translationName).tag(models.selectedTranslation) }
        }
        .disabled(!models.inUse.isEmpty)
    }

    private var selection: Binding<String> {
        Binding(get: { models.selectedTranslation }, set: { models.selectedTranslation = $0 })
    }

    private var isListed: Bool {
        let selected = models.selectedTranslation
        if let provider = models.cloudProvider { return models.configuredCloud.contains(provider) }
        if selected.hasPrefix(ModelStore.sidecarPrefix) { return models.sidecarAvailable }
        return models.translationModel != nil
    }

    private func cloudLabel(_ provider: CloudProvider) -> String {
        let model = models.cloudConfig.model(for: provider)
        // Model first: a narrow popup then cuts the provider, not "(free)".
        return "\(provider.model(model)?.label ?? model) · \(provider.name)"
    }

    @ViewBuilder
    private var remark: some View {
        if let provider = models.cloudProvider {
            CloudPrivacyLine(provider: provider)
            if mode == .translate {
                NoticeRow(symbol: "exclamationmark.triangle",
                          text: "Each sentence is a separate request: adds network lag and uses many requests (a 2-hour film ≈ 1,000+). Offline MADLAD is recommended for live.",
                          tone: .caution)
            }
        } else if models.translationModel == nil, !models.selectedTranslation.hasPrefix(ModelStore.sidecarPrefix) {
            HStack(spacing: 6) {
                NoticeRow(symbol: "arrow.down.circle", text: "Download a translation model first.", tone: .caution)
                Button("Models…", action: openModels).buttonStyle(.link).font(.caption)
            }
        } else {
            HStack(spacing: 6) {
                HelpNote("Offline: translated on this Mac, nothing is sent anywhere.")
                if models.configuredCloud.isEmpty {
                    Button("Cloud options…", action: openModels).buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

/// The one line every cloud choice carries.
struct CloudPrivacyLine: View {
    let provider: CloudProvider

    var body: some View {
        NoticeRow(symbol: "icloud.and.arrow.up",
                  text: provider.id == CloudProvider.custom.id
                      ? "Subtitle text is sent to your server. Audio never leaves the Mac."
                      : "Subtitle text is sent to \(provider.name). Audio never leaves the Mac. The provider may charge you on paid plans.")
    }
}

/// Before a whole-file cloud run: how much will be sent, how long it takes, how much of
/// today's free quota it uses. Nothing is sent until the user presses Start.
struct CloudEstimateView: View {
    let estimate: CloudEstimate
    let provider: CloudProvider
    let freeTier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if estimate.requests == 0 {
                NoticeRow(symbol: "checkmark.circle", text: "Cached: watching again sends nothing.", tone: .done)
            } else {
                NoticeRow(symbol: "paperplane", text: summary)
                LearnMore {
                    Text("\(estimate.cues) subtitle lines make \(estimate.groups) sentences; \(estimate.groups - estimate.remaining) are already translated. They go \(CloudTranslator.defaultBatchSize) at a time, plus one request where the AI reads the whole script to work out who's who: about \(estimate.requests) requests.")
                    if freeTier, let limits = provider.model(CloudConfig(defaults: .standard).model(for: provider))?.freeLimits {
                        Text("Free tier, approximate: \(limitText(limits)). Limits change often; check \(provider.name)'s page.")
                    }
                    Text("Translations are saved next to the subtitle file, so watching again sends nothing.")
                    if let page = provider.pricingPage {
                        Link("\(provider.name) pricing", destination: page)
                    }
                }
            }
        }
    }

    private var summary: String {
        var text = "≈ \(estimate.requests) request\(estimate.requests == 1 ? "" : "s") to \(provider.name), \(estimate.durationText)"
        if freeTier, let share = estimate.dailyShare {
            text += " · about \(max(1, Int((share * 100).rounded())))% of today's free requests"
        }
        return text + "."
    }

    private func limitText(_ limits: RateLimits) -> String {
        [limits.requestsPerMinute.map { "\($0) requests/min" }, limits.requestsPerDay.map { "\($0)/day" }]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// "Waiting for <provider>'s rate limit… 12 s", counting down.
struct RateLimitCountdown: View {
    let provider: String
    @ObservedObject var activity = CloudActivity.shared

    var body: some View {
        if let until = activity.waitingUntil, until > Date() {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                NoticeRow(symbol: "hourglass", text: "Waiting for \(provider)'s rate limit… \(seconds) s")
            }
        }
    }
}

/// "Notes about the characters": helps a cloud translator choose casual or polite speech.
struct CharacterNotesField: View {
    let file: URL?
    @StateObject private var text = Draft()

    final class Draft: ObservableObject { @Published var value = "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes about the characters (optional)")
            TextField("e.g. Mina and Jin-woo are siblings; Mr. Park is their boss.", text: $text.value, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.value) { CharacterNotes.set($0, for: file) }
            HelpNote("Before translating, the AI reads the whole script and works out who's who. Anything you add here is trusted over its guesses, and decides casual or polite speech between characters.")
        }
        .onAppear { text.value = CharacterNotes.get(for: file) }
        .onChange(of: file) { text.value = CharacterNotes.get(for: $0) }
    }
}
