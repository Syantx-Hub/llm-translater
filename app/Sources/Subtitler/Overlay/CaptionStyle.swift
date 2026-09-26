import AppKit
import SwiftUI

/// How captions look and where they sit. Shared by the live overlay and the preview in
/// the Captions window, so every change shows up in both immediately. Persisted.
@MainActor
final class CaptionStyle: ObservableObject {
    enum FontChoice: String, CaseIterable, Identifiable {
        /// Noto Sans Myanmar for Burmese, the system font for everything else.
        case automatic
        case notoSansMyanmar, myanmarSangam, myanmarMN, system, rounded, serif
        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: "Automatic"
            case .notoSansMyanmar: "Noto Sans Myanmar"
            case .myanmarSangam: "Myanmar Sangam MN"
            case .myanmarMN: "Myanmar MN"
            case .system: "San Francisco"
            case .rounded: "SF Rounded"
            case .serif: "New York"
            }
        }
    }

    enum Weight: String, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var fontWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    enum Position: String, CaseIterable, Identifiable {
        case bottom, top
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum Edge: String, CaseIterable, Identifiable {
        case shadow, outline, none
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var font: FontChoice { didSet { save(font.rawValue, "font") } }
    @Published var weight: Weight { didSet { save(weight.rawValue, "weight") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    @Published var lineSpacing: Double { didSet { save(lineSpacing, "lineSpacing") } }
    @Published var textColor: Color { didSet { saveColor(textColor, "textColor") } }
    @Published var edge: Edge { didSet { save(edge.rawValue, "edge") } }
    @Published var backgroundColor: Color { didSet { saveColor(backgroundColor, "backgroundColor") } }
    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, "backgroundOpacity") } }
    @Published var cornerRadius: Double { didSet { save(cornerRadius, "cornerRadius") } }
    @Published var position: Position { didSet { save(position.rawValue, "position") } }
    /// Distance from the top or bottom edge, as a fraction of the screen height.
    @Published var offset: Double { didSet { save(offset, "offset") } }
    /// Maximum caption width, as a fraction of the screen width.
    @Published var maxWidth: Double { didSet { save(maxWidth, "maxWidth") } }
    /// How many recent lines stay on screen.
    @Published var lineCount: Int { didSet { save(lineCount, "lineCount") } }
    @Published var showOriginal: Bool { didSet { save(showOriginal, "showOriginal") } }
    @Published var originalScale: Double { didSet { save(originalScale, "originalScale") } }
    /// Show in-progress text while someone is still speaking.
    @Published var showDrafts: Bool { didSet { save(showDrafts, "showDrafts") } }
    /// Seconds of quiet before captions clear.
    @Published var hideAfter: Double { didSet { save(hideAfter, "hideAfter") } }

    private let defaults = UserDefaults.standard
    private static let prefix = "caption."

    init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String) -> T? { d.object(forKey: Self.prefix + key) as? T }
        font = value("font").flatMap(FontChoice.init) ?? .automatic
        weight = value("weight").flatMap(Weight.init) ?? .medium
        // Older builds stored the size without the prefix.
        fontSize = value("fontSize") ?? (d.object(forKey: "fontSize") as? Double) ?? 34
        lineSpacing = value("lineSpacing") ?? 0.35
        textColor = Self.color(value("textColor")) ?? .white
        edge = value("edge").flatMap(Edge.init) ?? .shadow
        backgroundColor = Self.color(value("backgroundColor")) ?? .black
        backgroundOpacity = value("backgroundOpacity") ?? 0.62
        cornerRadius = value("cornerRadius") ?? 10
        position = value("position").flatMap(Position.init) ?? .bottom
        offset = value("offset") ?? 0.06
        maxWidth = value("maxWidth") ?? 0.84
        lineCount = value("lineCount") ?? 2
        showOriginal = value("showOriginal") ?? (d.object(forKey: "showOriginal") as? Bool) ?? true
        originalScale = value("originalScale") ?? 0.5
        showDrafts = value("showDrafts") ?? true
        hideAfter = value("hideAfter") ?? 6
    }

    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        let fresh = CaptionStyle()
        font = fresh.font; weight = fresh.weight; fontSize = 34; lineSpacing = fresh.lineSpacing
        textColor = fresh.textColor; edge = fresh.edge; backgroundColor = fresh.backgroundColor
        backgroundOpacity = fresh.backgroundOpacity; cornerRadius = fresh.cornerRadius
        position = fresh.position; offset = fresh.offset; maxWidth = fresh.maxWidth
        lineCount = fresh.lineCount; showOriginal = true; originalScale = fresh.originalScale
        showDrafts = fresh.showDrafts; hideAfter = fresh.hideAfter
    }

    /// The caption font for text in `language`, scaled by `scale` (for previews).
    func captionFont(for language: String, scale: Double = 1) -> Font {
        let size = fontSize * scale
        let family: String? = switch font {
        case .automatic: language == "my" ? "Noto Sans Myanmar" : nil
        case .notoSansMyanmar: "Noto Sans Myanmar"
        case .myanmarSangam: "Myanmar Sangam MN"
        case .myanmarMN: "Myanmar MN"
        case .system, .rounded, .serif: nil
        }
        if let family { return .custom(family, size: size).weight(weight.fontWeight) }
        let design: Font.Design = font == .rounded ? .rounded : font == .serif ? .serif : .default
        return .system(size: size, weight: weight.fontWeight, design: design)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    private func saveColor(_ color: Color, _ key: String) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        save([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent], key)
    }

    private static func color(_ components: [Double]?) -> Color? {
        guard let c = components, c.count == 4 else { return nil }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
    }
}
