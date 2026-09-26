import SwiftUI

/// Models › Cloud: set up a cloud (or local) LLM translator with your own key.
///
/// The key is typed into a SecureField, saved straight to the Keychain and cleared from
/// memory; afterwards only "••••1234" is ever shown.
struct CloudSection: View {
    @ObservedObject var store: ModelStore
    @StateObject private var setup = CloudSetup()

    private var provider: CloudProvider { setup.provider }
    private var config: CloudConfig { store.cloudConfig }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud translation (optional)").font(.title3.weight(.semibold))
                Text("An AI model online can word subtitles more naturally: it sees earlier lines, keeps names, and picks casual or polite speech from context. You bring your own API key. Offline stays the default, and nothing is sent unless you choose a cloud translator.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NoticeRow(symbol: "star", text: "Best for Subtitle file mode and Save Translated Copy: translated ahead, saved next to the file, so watching again sends nothing.")

            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $setup.providerID) {
                    ForEach(CloudProvider.all) { item in
                        Text(item.name + (store.configuredCloud.contains(item) ? " · set up" : "")).tag(item.id)
                    }
                }
                .frame(maxWidth: 360)

                if provider.id == CloudProvider.custom.id { customAddress }
                keyRow
                modelRow
                if provider.hasFreeTier {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("I'm on the free tier", isOn: Binding(
                            get: { config.usesFreeTier(provider) },
                            set: { config.setUsesFreeTier($0, for: provider); setup.bump() }))
                        HelpNote("Spaces requests out to stay inside the free limits, and shows how much of today's quota a file uses.")
                    }
                }
                remarks
                actions
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .onChange(of: setup.providerID) { _ in setup.resetForProvider() }
        .onDisappear { setup.clearDraft() }
    }

    // MARK: Rows

    private var customAddress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Server address", text: Binding(
                    get: { config.customBaseURL },
                    set: { config.customBaseURL = $0; setup.bump(); store.refreshCloud() }),
                    prompt: Text("https://… or http://localhost:11434/v1"))
                    .textFieldStyle(.roundedBorder)
                ForEach(CloudProvider.localPresets, id: \.name) { preset in
                    Button(preset.name) { config.customBaseURL = preset.url; setup.bump(); store.refreshCloud() }
                }
            }
            HelpNote("Any OpenAI-compatible server. Ollama and LM Studio run models on this Mac for free; secure https is required for anything else.")
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = store.keyHints[provider.id], !setup.replacing {
                HStack(spacing: 8) {
                    Label("Key \(hint)", systemImage: "key.fill")
                        .monospacedDigit()
                    Text("in your Keychain").foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") { setup.replacing = true; setup.bump() }
                    Button("Remove", role: .destructive) {
                        try? store.removeKey(for: provider)
                        setup.result = nil
                    }
                }
            } else {
                HStack {
                    SecureField(provider.keyRequired ? "API key" : "API key (optional)", text: setup.draftBinding)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save") { saveKey() }
                        .disabled(!setup.hasDraft)
                    if setup.replacing {
                        Button("Cancel") { setup.replacing = false; setup.clearDraft() }
                    }
                }
                if let error = setup.keyError { NoticeRow(symbol: "exclamationmark.triangle", text: error, tone: .caution) }
            }
            HStack(spacing: 4) {
                if let page = provider.keyPage {
                    HelpNote("Get a key at")
                    Link(page.host ?? page.absoluteString, destination: page).font(.caption)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                }
                HelpNote(provider.freeTier == nil
                         ? (provider.id == CloudProvider.custom.id ? "Local servers usually need no key." : "No free tier: paid use only.")
                         : "Has a free tier.")
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if provider.models.isEmpty || setup.typingModel {
                HStack {
                    TextField("Model", text: Binding(
                        get: { config.model(for: provider) },
                        set: { config.setModel($0.trimmingCharacters(in: .whitespaces), for: provider); setup.bump(); store.refreshCloud() }),
                        prompt: Text(provider.id == CloudProvider.custom.id ? "e.g. gemma3" : "model ID"))
                        .textFieldStyle(.roundedBorder)
                    if !provider.models.isEmpty {
                        Button("Choose from List") { setup.typingModel = false; setup.bump() }
                    }
                }
            } else {
                HStack {
                    Picker("Model", selection: Binding(
                        get: { config.model(for: provider) },
                        set: { config.setModel($0, for: provider); setup.bump(); store.refreshCloud() })) {
                        ForEach(provider.models) { Text($0.label).tag($0.id) }
                        if provider.model(config.model(for: provider)) == nil {
                            Text(config.model(for: provider)).tag(config.model(for: provider))
                        }
                    }
                    .frame(maxWidth: 360)
                    Button("Type an ID…") { setup.typingModel = true; setup.bump() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            HelpNote("Faster models translate a film in minutes; the best-quality ones cost more per line.")
        }
    }

    private var remarks: some View {
        VStack(alignment: .leading, spacing: 6) {
            CloudPrivacyLine(provider: provider)
            if let free = provider.freeTier {
                NoticeRow(symbol: "gift", text: "\(free) Approximate; check \(provider.name)'s page.")
            }
            LearnMore {
                ForEach(provider.freeTierNotes, id: \.self) { Text("• " + $0) }
                Text("• " + provider.dataUse)
                Text("• In live Translate mode each sentence is a separate request (a 2-hour film ≈ 1,000+), which adds network lag. Offline MADLAD is recommended for live.")
                HStack(spacing: 12) {
                    if let page = provider.pricingPage { Link("Pricing", destination: page) }
                    if let page = provider.limitsPage { Link("Rate limits", destination: page) }
                }
                .font(.caption)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            Button {
                test()
            } label: {
                if setup.testing { ProgressView().controlSize(.small) } else { Text("Test") }
            }
            .disabled(setup.testing || !config.isConfigured(provider, secrets: store.secrets))
            .help("Sends one short line to check the key, model and address.")
            if store.cloudProvider == provider {
                Label("In use for translation", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Button("Use Offline Instead") { store.selectedTranslation = ModelCatalog.defaultTranslation }
                    .disabled(!store.inUse.isEmpty)
            } else {
                Button("Use for Translation") { store.selectCloud(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.configuredCloud.contains(provider) || !store.inUse.isEmpty)
            }
            Spacer()
        }
        if let result = setup.result {
            NoticeRow(symbol: result.ok ? "checkmark.circle" : "exclamationmark.triangle", text: result.message,
                      tone: result.ok ? .done : .caution)
        }
        }
    }

    // MARK: Actions

    private func saveKey() {
        do {
            try store.saveKey(setup.takeDraft(), for: provider)
            setup.replacing = false
            setup.keyError = nil
            setup.result = nil
        } catch {
            setup.keyError = error.localizedDescription
        }
        setup.bump()
    }

    private func test() {
        let provider = provider
        let secrets = store.secrets
        guard let translator = try? config.translator(for: provider, secrets: secrets, onEvent: { CloudActivity.post($0) }) else {
            setup.result = (false, "Check the address: it must start with https:// (or http://localhost).")
            return
        }
        setup.testing = true
        setup.result = nil
        Task {
            do {
                let reply = try await translator.test()
                setup.result = (true, "Works. \"Hello, how are you?\" → \(reply)")
            } catch {
                setup.result = (false, CloudHTTP.redact(error.localizedDescription, secrets: []))
            }
            setup.testing = false
        }
    }
}

/// View state for the cloud card. The typed key is deliberately not @Published and is
/// dropped as soon as it's saved or the window closes.
@MainActor
final class CloudSetup: ObservableObject {
    @Published var providerID = CloudProvider.openRouter.id
    @Published var replacing = false
    @Published var typingModel = false
    @Published var testing = false
    @Published var result: (ok: Bool, message: String)?
    @Published var keyError: String?
    /// Redraws after a change stored outside (UserDefaults, the draft).
    @Published private var revision = 0

    private var draft = ""

    var provider: CloudProvider { CloudProvider.provider(providerID) ?? .openRouter }

    var draftBinding: Binding<String> {
        Binding(get: { self.draft }, set: { [weak self] in
            let hadDraft = self?.hasDraft ?? false
            self?.draft = $0
            if hadDraft != (self?.hasDraft ?? false) { self?.bump() }
        })
    }

    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func takeDraft() -> String {
        defer { draft = "" }
        return draft
    }

    func clearDraft() { draft = "" }
    func bump() { revision += 1 }

    func resetForProvider() {
        clearDraft()
        replacing = false
        typingModel = false
        result = nil
        keyError = nil
    }
}
