import SwiftUI

/// One downloadable model: what it is good at, what it costs, and its download state.
struct ModelCard: View {
    let model: ModelInfo
    @ObservedObject var store: ModelStore
    var compact = false

    private var status: ModelStore.Status { store.status(of: model) }
    /// Loaded by a live or starting session.
    private var locked: Bool { store.inUse.contains(model.id) }
    private var selected: Bool { store.isSelected(model) && store.isInstalled(model) }
    /// Speech has one pick; translation has one for movies and one for live Translate.
    private var recommendation: String? {
        switch model.id {
        case ModelCatalog.recommendedSpeech where model.kind == .speech: "Recommended"
        case ModelCatalog.recommendedTranslation: "Recommended for movies"
        case ModelCatalog.recommendedLiveTranslation: "Recommended for live"
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                titleRow
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.strengths, id: \.self) { point in
                            Label(point, systemImage: "checkmark")
                                .font(.caption)
                                .labelStyle(StrengthLabelStyle())
                        }
                    }
                }
                stats
                if !model.isBuiltIn { MemoryFit(model: model) }
            }
            Spacer(minLength: 8)
            actions
                .frame(width: 118, alignment: .trailing)
        }
        .padding(compact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
        )
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(model.name).font(.headline)
            if let recommendation { Badge(text: recommendation, color: .accentColor) }
            if model.englishOnly { Badge(text: "English only", color: .secondary) }
            if !model.commercialUse { Badge(text: "Non-commercial", color: .orange) }
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            Meter(label: "Speed", value: model.speed)
            Meter(label: model.kind == .speech ? "Accuracy" : "Quality", value: model.quality)
            Label(model.sizeLabel, systemImage: "internaldrive")
            Label(model.license, systemImage: "doc.text")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .notInstalled:
            Button("Download") { store.download(model) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Download \(model.name), \(model.sizeLabel)")
        case .downloading(let fraction):
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: fraction)
                HStack(spacing: 6) {
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                    Button("Cancel") { store.cancelDownload(model) }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        case .installed:
            VStack(alignment: .trailing, spacing: 6) {
                if selected {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.callout.weight(.medium))
                } else {
                    Button("Use") { store.select(model) }
                        .disabled(!store.inUse.isEmpty)
                        .help(!store.inUse.isEmpty ? "Stop subtitles to switch models."
                              : model.fit() == .tooBig ? "This Mac has less memory than this model needs; it may fail to load." : "")
                }
                if model.isBuiltIn {
                    Text("Built into macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if locked {
                    Text("Stop subtitles to delete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Delete", role: .destructive) { store.delete(model) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityLabel("Delete \(model.name)")
                }
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Button("Retry") { store.download(model) }
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3).multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// The memory a model needs and wants, and whether this Mac has it.
struct MemoryFit: View {
    let model: ModelInfo
    var ramGB = Hardware.ramGB

    var body: some View {
        Label {
            Text(verdict).foregroundStyle(tone) + Text(" · " + requirement).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone)
        }
        .font(.caption)
        .help("Memory (RAM) is shared by the GPU and every app. Below the minimum the model swaps to disk or fails to load; between the minimum and the recommended amount it runs if other apps are closed.")
    }

    var requirement: String {
        model.recommendedRAM > model.minRAMGB
            ? "needs \(model.minRAMGB) GB, \(model.recommendedRAM) GB recommended"
            : "needs \(model.minRAMGB) GB"
    }

    var verdict: String {
        switch model.fit(ramGB: ramGB) {
        case .comfortable: "Runs well on this Mac (\(ramGB) GB)"
        case .tight: "May run on this Mac (\(ramGB) GB) with other apps closed"
        case .tooBig: "Too big for this Mac (\(ramGB) GB)"
        }
    }

    private var symbol: String {
        switch model.fit(ramGB: ramGB) {
        case .comfortable: "checkmark.circle.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .tooBig: "xmark.octagon.fill"
        }
    }

    private var tone: Color {
        switch model.fit(ramGB: ramGB) {
        case .comfortable: .green
        case .tight: .orange
        case .tooBig: .red
        }
    }
}

/// Five-step bar, e.g. Speed ●●●●○.
private struct Meter: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(label).fixedSize()
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { step in
                    Capsule()
                        .fill(step <= value ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) of 5")
    }
}

private struct StrengthLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.foregroundStyle(.green).font(.caption2.weight(.bold))
            configuration.title
        }
    }
}
