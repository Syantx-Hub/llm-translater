import SwiftUI

struct SubtitleOverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(state.lines) { line in
                VStack(spacing: 4) {
                    Text(line.translation)
                        .font(SubtitleFont.font(for: state.targetLanguage, size: state.fontSize))
                        .foregroundStyle(.white)
                        // Burmese stacks marks above and below the base consonant.
                        .lineSpacing(state.fontSize * 0.35)
                    if state.showOriginal, line.original != line.translation {
                        Text(line.original)
                            .font(.system(size: state.fontSize * 0.5))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .subtitleBox(verticalPadding: state.fontSize * 0.3)
                .transition(.opacity)
            }
            if !state.draft.isEmpty {
                Text(state.draft)
                    .font(.system(size: state.fontSize * 0.55))
                    .foregroundStyle(.gray)
                    .subtitleBox(verticalPadding: 6)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: state.lines)
    }
}

enum SubtitleFont {
    /// Noto Sans Myanmar ships with macOS and shapes stacked consonants correctly.
    static func font(for language: String, size: Double) -> Font {
        language == "my" ? .custom("Noto Sans Myanmar", size: size).weight(.medium) : .system(size: size, weight: .semibold)
    }
}

private extension View {
    func subtitleBox(verticalPadding: Double) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, verticalPadding)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 4)
    }
}
