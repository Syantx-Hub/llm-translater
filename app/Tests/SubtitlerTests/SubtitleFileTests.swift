import Foundation
import Testing
@testable import Subtitler

@Suite struct SubtitleFileTests {
    private let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    Where have you been
    all night?

    2
    00:00:04,000 --> 00:00:06,250
    <i>I was waiting.</i>

    3
    00:01:02,005 --> 00:01:04,000
    {\\an8}Nobody answered.
    """

    @Test func parsesSubRip() {
        let cues = SubtitleFile.parse(srt)
        #expect(cues.count == 3)
        #expect(cues[0] == SubtitleCue(start: 1, end: 3.5, text: "Where have you been\nall night?"))
        #expect(abs(cues[2].start - 62.005) < 0.0001)
    }

    @Test func parsesWebVTTWithHeaderIdentifiersAndSettings() {
        let vtt = """
        WEBVTT

        intro
        00:01.000 --> 00:02.500 align:start position:10%
        Hello there.

        00:00:03.000 --> 00:00:04.000
        General Kenobi.
        """
        let cues = SubtitleFile.parse(vtt)
        #expect(cues.map(\.text) == ["Hello there.", "General Kenobi."])
        #expect(cues[0].start == 1 && cues[0].end == 2.5)
    }

    @Test func toleratesWindowsLineEndingsBOMAndBrokenBlocks() {
        let messy = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nOne.\r\n\r\ngarbage block\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nTwo.\r\n"
        #expect(SubtitleFile.parse(messy).map(\.text) == ["One.", "Two."])
    }

    @Test func writesSubRipThatReadsBack() {
        let cues = SubtitleFile.parse(srt)
        let written = SubtitleFile.srt(cues)
        #expect(written.hasPrefix("1\n00:00:01,000 --> 00:00:03,500\n"))
        #expect(SubtitleFile.parse(written) == cues)
    }

    @Test func plainTextDropsTagsAndLineBreaks() {
        #expect(SubtitleFile.plainText("<i>I was</i>\nwaiting.") == "I was waiting.")
        #expect(SubtitleFile.plainText("{\\an8}<font color=\"#fff\">Hi</font>") == "Hi")
    }

    @Test func outputIsNamedForPlayersAndNeverOverwrites() throws {
        let folder = try makeTemporaryDirectory()
        let english = folder.appendingPathComponent("Movie.en.srt")
        #expect(SubtitleFile.outputURL(for: english, target: "my").lastPathComponent == "Movie.my.srt")
        #expect(SubtitleFile.outputURL(for: folder.appendingPathComponent("Movie.2024.HD.srt"), target: "my")
            .lastPathComponent == "Movie.2024.HD.my.srt")
        try Data().write(to: folder.appendingPathComponent("Movie.my.srt"))
        #expect(SubtitleFile.outputURL(for: english, target: "my").lastPathComponent == "Movie.my 2.srt")
    }

    @Test func readRejectsFilesWithoutSubtitles() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("empty.srt")
        try Data("just some text".utf8).write(to: url)
        #expect(throws: SubtitleFileError.noCues) { try SubtitleFile.read(url) }
    }
}

@Suite struct SubtitleTranslatorTests {
    @Test func translatesEveryCueAndKeepsTiming() async throws {
        let cues = [
            SubtitleCue(start: 1, end: 2, text: "<i>Where</i>\nwere you?"),
            SubtitleCue(start: 3, end: 4, text: "Yes."),
            SubtitleCue(start: 5, end: 6, text: "Yes."),
        ]
        let translator = FakeTranslator()
        let progress = Recorder<Int>()
        let result = try await SubtitleTranslator.translate(cues, from: "en", to: "my", with: translator) {
            progress.append($0.done)
        }
        #expect(result.map(\.text) == ["[my] Where were you?", "[my] Yes.", "[my] Yes."])
        #expect(result.map(\.start) == [1, 3, 5])
        #expect(await translator.calls == ["Where were you?", "Yes."]) // repeated lines once
        #expect(progress.values == [1, 2, 3])
    }

    @Test func joinsASentenceSplitOverCuesIntoOneCue() async throws {
        let cues = [
            SubtitleCue(start: 1, end: 2, text: "I told you"),
            SubtitleCue(start: 2.2, end: 3.5, text: "not to go there."),
            SubtitleCue(start: 4, end: 5, text: "Why?"),
        ]
        let translator = FakeTranslator()
        let result = try await SubtitleTranslator.translate(cues, from: "en", to: "my", with: translator) { _ in }
        #expect(result == [
            SubtitleCue(start: 1, end: 3.5, text: "[my] I told you not to go there."),
            SubtitleCue(start: 4, end: 5, text: "[my] Why?"),
        ])
    }

    @Test func stopsWhenCancelled() async {
        let cues = (0..<50).map { SubtitleCue(start: Double($0), end: Double($0) + 1, text: "Line \($0).") }
        let translator = FakeTranslator(delays: Dictionary(uniqueKeysWithValues: cues.map { ($0.text, .milliseconds(20)) }))
        let task = Task { try await SubtitleTranslator.translate(cues, from: "en", to: "my", with: translator) { _ in } }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await translator.calls.count < 50)
    }
}

@Suite struct SubtitleSentencesTests {
    private func groups(_ lines: [(Double, Double, String)]) -> [[Int]] {
        SubtitleSentences(cues: lines.map { SubtitleCue(start: $0.0, end: $0.1, text: $0.2) }).groups
    }

    @Test func joinsCuesUntilTheSentenceEnds() {
        #expect(groups([(0, 1, "When I got home,"), (1.2, 2, "the door was open"), (2.1, 3, "and nobody was there."),
                        (3.5, 4, "Hello?")]) == [[0, 1, 2], [3]])
    }

    @Test func keepsFinishedSentencesApart() {
        #expect(groups([(0, 1, "Where were you?"), (1.1, 2, "Home."), (2.1, 3, "\"Go.\""), (3.1, 4, "Okay.")])
                == [[0], [1], [2], [3]])
    }

    @Test func aLongPauseEndsTheSentence() {
        #expect(groups([(0, 1, "I think"), (4, 5, "we should go."), (5.1, 6, "Now.")]) == [[0], [1], [2]])
    }

    @Test func anEllipsisContinuesOnlyIntoAContinuation() {
        #expect(groups([(0, 1, "I thought..."), (1.1, 2, "...you had left."), (2.1, 3, "Wait…"), (3.1, 4, "Who's there?")])
                == [[0, 1], [2], [3]])
    }

    @Test func dialogueDashesAreDifferentSpeakers() {
        #expect(groups([(0, 1, "- Where are you going"), (1.1, 2, "- Home."), (2.1, 3, "You should")
                        , (3.1, 4, "- Stop.")]) == [[0], [1], [2], [3]])
    }

    @Test func atMostThreeCuesPerSentence() {
        #expect(groups([(0, 1, "one"), (1, 2, "two"), (2, 3, "three"), (3, 4, "four."), (4, 5, "Five.")])
                == [[0, 1, 2], [3], [4]])
    }

    @Test func filesWithoutPunctuationStayAsTheyAre() {
        // Korean subtitles often have no full stops: nothing says where a sentence ends.
        #expect(groups([(0, 1, "어디 갔었어"), (1.1, 2, "밤새 기다렸잖아"), (2.1, 3, "미안해")]) == [[0], [1], [2]])
    }
}
