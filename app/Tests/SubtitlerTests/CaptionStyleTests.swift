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
    @Test func everySubtitleLanguageHasSampleLines() {
        for language in Languages.all {
            let lines = SampleCaptions.lines(language: language.code, translating: true)
            #expect(lines.count == 4, "\(language.code)")
            // Languages with written samples show a distinct original, for "Show original";
            // the rest preview with the English sample.
            if SampleCaptions.translations[language.code] != nil {
                #expect(lines.allSatisfy { $0.original != $0.translation }, "\(language.code)")
            }
        }
    }

    @Test func transcribeOnlyPreviewShowsTheSpokenWords() {
        let lines = SampleCaptions.lines(language: "my", translating: false)
        #expect(lines.allSatisfy { $0.original == $0.translation })
    }
}

@Suite struct CaptionSlotTests {
    private let one = SubtitleLine(original: "One.", translation: "တစ်။")
    private let two = SubtitleLine(original: "Two.", translation: "နှစ်။")
    private let live = DraftCaption(text: "သုံး", isTranslation: true)

    @Test func withOneLineOnlyTheSpokenLineShows() {
        let slots = CaptionSlot.slots(lines: [one, two], draft: live, lineCount: 1, showDrafts: true)
        #expect(slots.map(\.slot) == [.live(live)])
    }

    @Test func theFinishedLineTakesTheSpokenLinesPlace() {
        let speaking = CaptionSlot.slots(lines: [one], draft: live, lineCount: 1, showDrafts: true)
        let finished = CaptionSlot.slots(lines: [one, two], draft: nil, lineCount: 1, showDrafts: true)
        // Same identity, so the box updates in place instead of a new one appearing.
        #expect(speaking.map(\.id) == [CaptionSlot.currentID])
        #expect(finished.map(\.id) == [CaptionSlot.currentID])
        #expect(finished.map(\.slot) == [.line(two)])
    }

    @Test func lineCountIncludesTheSpokenLine() {
        let slots = CaptionSlot.slots(lines: [one, two], draft: live, lineCount: 2, showDrafts: true)
        #expect(slots.map(\.slot) == [.line(two), .live(live)])
    }

    @Test func hidingDraftsShowsOnlyFinishedLines() {
        let slots = CaptionSlot.slots(lines: [one, two], draft: live, lineCount: 1, showDrafts: false)
        #expect(slots.map(\.slot) == [.line(two)])
    }

    @Test func nothingToShow() {
        #expect(CaptionSlot.slots(lines: [], draft: nil, lineCount: 2, showDrafts: true).isEmpty)
    }
}

@Suite struct ScreenFitTests {
    @Test func windowsNeverRunPastTheScreen() {
        #expect(ScreenFit.height(680, visible: 1000) == 680)          // fits: design height
        #expect(ScreenFit.height(680, visible: 700) == 640)           // short screen: what fits
        #expect(ScreenFit.height(680, visible: 300) == 360)           // tiny: a usable minimum, scrolling
    }
}
