import SwiftUI

/// In-progress text for the line being spoken, shown in the same style as finished lines.
/// `isTranslation` is false while only the source words are known.
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

/// What one caption box shows.
enum CaptionSlot: Equatable {
    case line(SubtitleLine)
    case live(DraftCaption)

    /// The bottom slot keeps one identity whether it holds the words being spoken or the
    /// line they became, so the text updates in place instead of a new box appearing.
    static let currentID = "current"

    /// The last `lineCount` boxes, counting the line being spoken: earlier finished lines,
    /// then the live words (or, between sentences, the latest finished line).
    static func slots(lines: [SubtitleLine], draft: DraftCaption?, lineCount: Int, showDrafts: Bool) -> [(id: String, slot: CaptionSlot)] {
        let live = showDrafts ? draft.flatMap { $0.text.isEmpty ? nil : $0 } : nil
        var finished = Array(lines.suffix(max(lineCount, 1)))
        let current: CaptionSlot?
        if let live {
            current = .live(live)
            finished = Array(finished.suffix(max(lineCount - 1, 0)))
        } else {
            current = finished.popLast().map(CaptionSlot.line)
        }
        return finished.map { ($0.id.uuidString, .line($0)) } + (current.map { [(currentID, $0)] } ?? [])
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
        let slots = CaptionSlot.slots(lines: lines, draft: draft, lineCount: style.lineCount, showDrafts: style.showDrafts)
        GeometryReader { geometry in
            VStack(spacing: 8 * scale) {
                ForEach(slots, id: \.id) { item in
                    CaptionBox(style: style, scale: scale) { content(item.slot) }
                        .transition(.opacity)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: geometry.size.width * style.maxWidth)
            .padding(style.position == .bottom ? .bottom : .top, geometry.size.height * style.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: style.position == .bottom ? .bottom : .top)
            .animation(.easeOut(duration: 0.15), value: slots.map(\.id))
        }
    }

    @ViewBuilder
    private func content(_ slot: CaptionSlot) -> some View {
        switch slot {
        case .line(let line):
            captionText(line.translation)
            if style.showOriginal, line.original != line.translation {
                Text(line.original)
                    .font(.system(size: style.fontSize * style.originalScale * scale))
                    .foregroundStyle(style.textColor.opacity(0.7))
            }
        case .live(let draft):
            // Exactly the style of the finished line it turns into, so every caption
            // setting applies to both and nothing jumps when the line is finished.
            captionText(draft.text)
        }
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(style.captionFont(for: language, scale: scale))
            .foregroundStyle(style.textColor)
            .lineSpacing(style.fontSize * style.lineSpacing * scale)
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
