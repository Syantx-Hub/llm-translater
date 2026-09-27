import SwiftUI

/// Models › Film background: the opt-in lookup, the optional TMDB key, and the cache.
struct FilmBackgroundSection: View {
    @ObservedObject var store: ModelStore
    @StateObject private var state = SectionState()

    final class SectionState: ObservableObject {
        @Published var enabled = FilmBackgroundSettings().lookupEnabled
        @Published var draft = ""
        @Published var hasKey = false
        @Published var saved = FilmBackgroundCache.app.count
        @Published var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Film background (optional)").font(.title3.weight(.semibold))
                Text("Knowing who the characters are (a mother and her son, a boss and his staff) lets an AI translator pick the right pronouns and politeness. Used by cloud AIs and Gemma; MADLAD ignores it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(FilmBackgroundSettings.toggleLabel, isOn: Binding(
                        get: { state.enabled },
                        set: { state.enabled = $0; FilmBackgroundSettings().lookupEnabled = $0 }))
                    HelpNote("Only the title and year from the file name. Never subtitle text, audio or file paths. Reads the cast list and the opening paragraph, never the plot. Each film is looked up once and saved on this Mac; you can check and edit what was found before translating.")
                }
                tmdbKey
                HStack(spacing: 8) {
                    Button("Clear saved backgrounds") {
                        FilmBackgroundCache.app.clear()
                        FilmBackgroundNotes.clearAll()
                        state.saved = 0
                    }
                    .disabled(state.saved == 0)
                    HelpNote(state.saved == 0 ? "Nothing saved yet." : "\(state.saved) saved on this Mac.")
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .onAppear {
            state.hasKey = store.secrets.contains(TMDB.secretName)
            state.saved = FilmBackgroundCache.app.count
        }
        .onDisappear { state.draft = "" }
    }

    @ViewBuilder
    private var tmdbKey: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.hasKey {
                HStack(spacing: 8) {
                    Label("TMDB key saved", systemImage: "key.fill")
                    Text("in your Keychain").foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        try? store.secrets.delete(TMDB.secretName)
                        state.hasKey = false
                    }
                }
            } else {
                HStack {
                    SecureField("TMDB API Read Access Token (optional)", text: $state.draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = state.error { NoticeRow(symbol: "exclamationmark.triangle", text: error, tone: .caution) }
            }
            HStack(spacing: 4) {
                HelpNote("Adds full cast lists, and episode casts for series. Free at")
                Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org/settings/api")!).font(.caption)
                HelpNote("· Wikipedia needs no key.")
            }
        }
    }

    private func saveKey() {
        let key = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try store.secrets.save(key, for: TMDB.secretName)
            state.hasKey = true
            state.error = nil
        } catch {
            state.error = error.localizedDescription
        }
        state.draft = ""
    }
}

/// The film's background next to the character notes: where it came from, and the text
/// itself, editable before translating.
struct FilmBackgroundField: View {
    let file: URL?
    let target: String
    @StateObject private var model = Model()

    @MainActor
    final class Model: ObservableObject {
        @Published var text = ""
        @Published var looking = false
        @Published var notFound = false
        var task: Task<Void, Never>?

        func load(_ file: URL?) {
            task?.cancel()
            looking = false
            notFound = false
            text = FilmBackgroundNotes.get(for: file)
        }

        func lookUp(_ file: URL?, target: String) {
            task?.cancel()
            looking = true
            notFound = false
            FilmBackgroundNotes.set("", for: file)
            task = Task {
                let found = await FilmBackgroundNotes.resolve(for: file, target: target)
                guard !Task.isCancelled else { return }
                text = found
                notFound = found.isEmpty
                looking = false
            }
        }
    }

    private var enabled: Bool { FilmBackgroundSettings().lookupEnabled }

    private var source: String? {
        let first = model.text.components(separatedBy: .newlines).first ?? ""
        return first.hasPrefix("From ") ? String(first.dropFirst(5)) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.looking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    HelpNote("Looking up \(FilmTitle.from(file) ?? "the film")…")
                }
            } else if !model.text.isEmpty {
                HStack(spacing: 6) {
                    Label(source.map { "Background from \($0)" } ?? "Film background", systemImage: "books.vertical")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if enabled {
                        Button("Reload") { model.lookUp(file, target: target) }.buttonStyle(.link).font(.caption)
                    }
                }
                TextField("Film background", text: $model.text, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: model.text) { FilmBackgroundNotes.set($0, for: file) }
                HelpNote("Trusted over the AI's guesses. Fix anything wrong, or delete lines you don't want used.")
            } else if enabled {
                HStack(spacing: 6) {
                    if model.notFound { HelpNote("Nothing clear found for “\(FilmTitle.from(file) ?? "this file")”; translating without it.") }
                    Button(model.notFound ? "Try again" : "Look up the cast") { model.lookUp(file, target: target) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .onAppear {
            model.load(file)
            if model.text.isEmpty, enabled, file != nil { model.lookUp(file, target: target) }
        }
        .onChange(of: file) { model.load($0) }
        .onDisappear { model.task?.cancel() }
    }
}
