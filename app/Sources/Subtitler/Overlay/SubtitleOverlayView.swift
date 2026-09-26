import SwiftUI

/// In-progress text for the line being spoken. Translated drafts show in the caption
/// font; untranslated ones as smaller grey source text.
struct DraftCaption: Equatable {
    let text: String
    let isTranslation: Bool
}

/// The live overlay: the current session's captions in the shared style.
struct SubtitleOverlayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var style: CaptionStyle

    var body: some View {
        CaptionLayer(style: style, lines: state.lines, draft: state.draft, language: state.captionLanguage)
    }
}

/// Lays captions out over an area the size of the screen (or a scaled-down preview of it).
struct CaptionLayer: View {
    @ObservedObject var style: CaptionStyle
    let lines: [SubtitleLine]
    let draft: DraftCaption?
    let language: String
    /// 1 on screen; smaller in the settings preview so it matches the real proportions.
    var scale: Double = 1

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8 * scale) {
                ForEach(lines.suffix(style.lineCount)) { line in
                    CaptionBox(style: style, scale: scale) {
                        Text(line.translation)
                            .font(style.captionFont(for: language, scale: scale))
                            .foregroundStyle(style.textColor)
                            .lineSpacing(style.fontSize * style.lineSpacing * scale)
                        if style.showOriginal, line.original != line.translation {
                            Text(line.original)
                                .font(.system(size: style.fontSize * style.originalScale * scale))
                                .foregroundStyle(style.textColor.opacity(0.7))
                        }
                    }
                    .transition(.opacity)
                }
                if style.showDrafts, let draft, !draft.text.isEmpty {
                    CaptionBox(style: style, scale: scale) {
                        if draft.isTranslation {
                            Text(draft.text)
                                .font(style.captionFont(for: language, scale: scale))
                                .foregroundStyle(style.textColor.opacity(0.6))
                                .lineSpacing(style.fontSize * style.lineSpacing * scale)
                        } else {
                            Text(draft.text)
                                .font(.system(size: style.fontSize * 0.55 * scale))
                                .foregroundStyle(style.textColor.opacity(0.55))
                        }
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: geometry.size.width * style.maxWidth)
            .padding(style.position == .bottom ? .bottom : .top, geometry.size.height * style.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: style.position == .bottom ? .bottom : .top)
            .animation(.easeOut(duration: 0.15), value: lines)
        }
    }
}

private struct CaptionBox<Content: View>: View {
    @ObservedObject var style: CaptionStyle
    let scale: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 4 * scale) { content }
            .modifier(TextEdge(edge: style.edge, scale: scale))
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, style.fontSize * 0.3 * scale)
            .background(
                style.backgroundColor.opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: style.cornerRadius * scale, style: .continuous))
    }
}

/// Keeps text readable on bright video when the background box is faint or off.
private struct TextEdge: ViewModifier {
    let edge: CaptionStyle.Edge
    let scale: Double

    func body(content: Content) -> some View {
        switch edge {
        case .shadow:
            content.shadow(color: .black.opacity(0.85), radius: 3 * scale, y: 1 * scale)
        case .outline:
            let width = 1.2 * scale
            content
                .shadow(color: .black, radius: 0, x: width, y: 0)
                .shadow(color: .black, radius: 0, x: -width, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: width)
                .shadow(color: .black, radius: 0, x: 0, y: -width)
        case .none:
            content
        }
    }
}
