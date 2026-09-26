import SwiftUI

/// Caption appearance settings with a live preview that redraws on every change.
struct CaptionsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var style: CaptionStyle

    private let previewWidth: Double = 460

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                Toggle("Preview on screen", isOn: $state.previewOnScreen)
                    .disabled(state.isRunning || state.isBusy)
                Text(state.isRunning
                     ? "Subtitles are live — changes apply to them right away."
                     : "Shows sample captions over your screen so you can fine-tune position and size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset to defaults") { style.reset() }
            }
            .frame(width: previewWidth)
            .padding(20)

            Divider()

            Form {
                Section("Text") {
                    Picker("Font", selection: $style.font) {
                        ForEach(CaptionStyle.FontChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Weight", selection: $style.weight) {
                        ForEach(CaptionStyle.Weight.allCases) { Text($0.label).tag($0) }
                    }
                    labeledSlider("Size", value: $style.fontSize, in: 18...72, format: "%.0f pt")
                    labeledSlider("Line spacing", value: $style.lineSpacing, in: 0...0.8, format: "%.2f")
                    ColorPicker("Text color", selection: $style.textColor, supportsOpacity: false)
                    Picker("Edge", selection: $style.edge) {
                        ForEach(CaptionStyle.Edge.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Background") {
                    ColorPicker("Background color", selection: $style.backgroundColor, supportsOpacity: false)
                    labeledSlider("Opacity", value: $style.backgroundOpacity, in: 0...1, format: "%.0f%%", scale: 100)
                    labeledSlider("Corner radius", value: $style.cornerRadius, in: 0...24, format: "%.0f")
                }
                Section("Layout") {
                    Picker("Position", selection: $style.position) {
                        ForEach(CaptionStyle.Position.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    labeledSlider("Distance from edge", value: $style.offset, in: 0...0.4, format: "%.0f%%", scale: 100)
                    labeledSlider("Max width", value: $style.maxWidth, in: 0.4...1, format: "%.0f%%", scale: 100)
                    Stepper("Lines on screen: \(style.lineCount)", value: $style.lineCount, in: 1...3)
                    labeledSlider("Clear after", value: $style.hideAfter, in: 2...15, format: "%.0f s")
                }
                Section("Content") {
                    Toggle("Show original under translation", isOn: $style.showOriginal)
                    if style.showOriginal {
                        labeledSlider("Original size", value: $style.originalScale, in: 0.3...0.9, format: "%.0f%%", scale: 100)
                    }
                    Toggle("Show text while someone is speaking", isOn: $style.showDrafts)
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)
        }
        .frame(height: 700)
        .onDisappear { state.previewOnScreen = false }
    }

    /// A 16:9 "video frame" at screen proportions, captioned exactly like the overlay.
    private var preview: some View {
        let screen = OverlayController.targetScreen?.frame.size ?? CGSize(width: 1440, height: 900)
        let height = previewWidth * screen.height / screen.width
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.3, blue: 0.42), Color(red: 0.55, green: 0.45, blue: 0.38),
                         Color(red: 0.85, green: 0.78, blue: 0.62)],
                startPoint: .top, endPoint: .bottom)
            // Bright shapes, so contrast problems show up in the preview.
            Circle().fill(.white.opacity(0.55)).frame(width: 90).offset(x: 130, y: -50)
            Rectangle().fill(.black.opacity(0.35)).frame(width: previewWidth, height: height * 0.18)
                .offset(y: height * 0.41)
            CaptionLayer(style: style, lines: state.sampleLines, draft: state.sampleDraft,
                         language: state.captionLanguage, scale: previewWidth / screen.width)
        }
        .frame(width: previewWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               format: String, scale: Double = 1) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}
