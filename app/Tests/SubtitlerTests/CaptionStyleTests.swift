import SwiftUI
import Testing
@testable import Subtitler

@Suite @MainActor struct CaptionStyleTests {
    @Test func changesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let style = CaptionStyle(defaults: defaults)
        style.fontSize = 48
        style.position = .top
        style.lineCount = 3
        style.font = .myanmarSangam
        style.textColor = Color(.sRGB, red: 1, green: 0.8, blue: 0, opacity: 1)

        let reloaded = CaptionStyle(defaults: defaults)
        #expect(reloaded.fontSize == 48)
        #expect(reloaded.position == .top)
        #expect(reloaded.lineCount == 3)
        #expect(reloaded.font == .myanmarSangam)
        let rgb = NSColor(reloaded.textColor).usingColorSpace(.sRGB)
        #expect(abs((rgb?.greenComponent ?? 0) - 0.8) < 0.01)
    }

    @Test func resetRestoresDefaultsAndClearsStoredValues() {
        let defaults = makeDefaults()
        let style = CaptionStyle(defaults: defaults)
        style.fontSize = 60
        style.showOriginal = true
        style.backgroundOpacity = 0.1

        style.reset()

        #expect(style.fontSize == 34)
        #expect(!style.showOriginal)
        #expect(style.backgroundOpacity == 0.62)
        #expect(CaptionStyle(defaults: defaults).fontSize == 34)
    }

    @Test func migratesSettingsFromOlderBuilds() {
        let defaults = makeDefaults()
        defaults.set(40.0, forKey: "fontSize")
        defaults.set(false, forKey: "showOriginal")
        let style = CaptionStyle(defaults: defaults)
        #expect(style.fontSize == 40)
        #expect(!style.showOriginal)
    }

    @Test func automaticFontUsesNotoSansMyanmarOnlyForBurmese() {
        let style = CaptionStyle(defaults: makeDefaults())
        #expect(style.captionFont(for: "my") == .custom("Noto Sans Myanmar", size: 34).weight(.medium))
        #expect(style.captionFont(for: "en") == .system(size: 34, weight: .medium, design: .default))
    }
}

@Suite struct SampleCaptionTests {
    @Test func everySubtitleLanguageHasFourDistinctSampleLines() {
        for language in Languages.all {
            let lines = SampleCaptions.lines(language: language.code, translating: true)
            #expect(lines.count == 4, "\(language.code)")
            // "Show original" needs something different from the translation to preview.
            #expect(lines.allSatisfy { $0.original != $0.translation }, "\(language.code)")
        }
    }

    @Test func transcribeOnlyPreviewShowsTheSpokenWords() {
        let lines = SampleCaptions.lines(language: "my", translating: false)
        #expect(lines.allSatisfy { $0.original == $0.translation })
    }
}
