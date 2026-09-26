import Foundation
import Testing
@testable import Subtitler

@Suite struct SubtitlePipelineTests {
    private func pipeline(
        transcriber: FakeTranscriber, translator: Translator = FakeTranslator(),
        source: String? = "en", target: String? = "my", translateDrafts: Bool = true
    ) -> (SubtitlePipeline, Recorder<SubtitlePipeline.Update>) {
        let updates = Recorder<SubtitlePipeline.Update>()
        let pipeline = SubtitlePipeline(
            transcriber: transcriber, translator: translator, source: source, target: target,
            translateDrafts: translateDrafts) { updates.append($0) }
        return (pipeline, updates)
    }

    private func lines(_ updates: Recorder<SubtitlePipeline.Update>) -> [(original: String, translation: String)] {
        updates.values.compactMap { if case .line(let o, let t, _) = $0 { (o, t) } else { nil } }
    }

    private func samples(_ count: Int) -> [Float] { [Float](repeating: 0.1, count: count) }

    @Test func finalReusesPauseDraftWithoutDecodingAgain() async {
        let transcriber = FakeTranscriber(script: [1000: "Hello there."])
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator)

        await pipeline.submit(.partial(samples(1000), isPause: true))
        await pipeline.flush()
        await pipeline.submit(.final(samples(1500), trailingSilence: 600))
        await pipeline.flush()

        #expect(await transcriber.calls == [1000])
        #expect(await translator.calls == ["Hello there."])
        #expect(lines(updates).map(\.translation) == ["[my] Hello there."])
    }

    /// The usual live timing: the final arrives while the pause draft is still decoding.
    @Test func finalReusesAPauseDraftThatWasStillDecoding() async {
        let transcriber = FakeTranscriber(script: [1000: "Hello there."], delay: .milliseconds(200))
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator)

        await pipeline.submit(.partial(samples(1000), isPause: true))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.submit(.final(samples(1500), trailingSilence: 600))
        await pipeline.flush()

        #expect(await transcriber.calls == [1000])
        #expect(lines(updates).map(\.original) == ["Hello there."])
    }

    @Test func finalDecodesAgainWhenNewSpeechFollowedTheDraft() async {
        let transcriber = FakeTranscriber(script: [1000: "Hello", 5000: "Hello there, friend."])
        let (pipeline, updates) = pipeline(transcriber: transcriber)

        await pipeline.submit(.partial(samples(1000), isPause: true))
        await pipeline.flush()
        await pipeline.submit(.final(samples(5000), trailingSilence: 600))
        await pipeline.flush()

        #expect(await transcriber.calls == [1000, 5000])
        #expect(lines(updates).map(\.original) == ["Hello there, friend."])
    }

    @Test func linesStayInSpeechOrderWhenTranslationsFinishOutOfOrder() async {
        let transcriber = FakeTranscriber(script: [100: "One.", 200: "Two.", 300: "Three."])
        let translator = FakeTranslator(delays: ["One.": .milliseconds(300), "Two.": .milliseconds(100)])
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator, translateDrafts: false)

        for count in [100, 200, 300] {
            await pipeline.submit(.final(samples(count), trailingSilence: 0))
        }
        await pipeline.flush()

        #expect(lines(updates).map(\.original) == ["One.", "Two.", "Three."])
    }

    @Test func translationFailureFallsBackToOriginalText() async {
        let transcriber = FakeTranscriber(script: [100: "Broken line."])
        let translator = FakeTranslator(failing: ["Broken line."])
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(updates.values.contains { if case .error = $0 { true } else { false } })
        #expect(lines(updates).map(\.translation) == ["Broken line."])
    }

    @Test func transcribeOnlyShowsTheOriginalWords() async {
        let transcriber = FakeTranscriber(script: [100: "Just the words."])
        let (pipeline, updates) = pipeline(
            transcriber: transcriber, translator: PassthroughTranslator(), target: nil, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).map(\.translation) == ["Just the words."])
    }

    @Test func sameSourceAndTargetSkipsTranslation() async {
        let transcriber = FakeTranscriber(script: [100: "Already Burmese."], language: "my")
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator, source: "my")

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(await translator.calls.isEmpty)
        #expect(lines(updates).map(\.translation) == ["Already Burmese."])
    }

    @Test func autoDetectionReportsTheLanguageOnce() async {
        let transcriber = FakeTranscriber(script: [100: "안녕.", 200: "잘 지내?"], language: "ko")
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: nil, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.submit(.final(samples(200), trailingSilence: 0))
        await pipeline.flush()

        let detected = updates.values.compactMap { if case .detectedLanguage(let code) = $0 { code } else { nil } }
        #expect(detected == ["ko"])
        #expect(lines(updates).count == 2)
    }

    @Test func silentFinalClearsTheDraftAndAddsNoLine() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]))

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).isEmpty)
        #expect(updates.values.contains(.draft(nil)))
    }

    @Test func draftsAreTranslatedWhileSpeaking() async {
        let transcriber = FakeTranscriber(script: [1000: "Where have you"])
        let (pipeline, updates) = pipeline(transcriber: transcriber)

        await pipeline.submit(.partial(samples(1000), isPause: true))
        await pipeline.flush()

        #expect(updates.values.contains(.draft(DraftCaption(text: "[my] Where have you", isTranslation: true))))
    }

    @Test func transcribeOnlyKeepsCJKPunctuationSpacing() async {
        let transcriber = FakeTranscriber(script: [100: "你好。我很好。"], language: "zh")
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: "zh", target: nil, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).map(\.translation) == ["你好。我很好。"])
    }

    @Test func cancelledPipelineEmitsNothingMore() async {
        let transcriber = FakeTranscriber(script: [100: "Late line."])
        let translator = FakeTranslator(delays: ["Late line.": .milliseconds(300)])
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.cancel()
        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        try? await Task.sleep(for: .milliseconds(400))

        #expect(lines(updates).isEmpty)
    }

    @Test func draftsDoNotLockTheDetectedLanguage() async {
        let transcriber = FakeTranscriber(script: [500: "short"], language: "ja")
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: nil)

        await pipeline.submit(.partial(samples(500), isPause: false))
        await pipeline.flush()

        #expect(!updates.values.contains { if case .detectedLanguage = $0 { true } else { false } })
    }

    // MARK: Streaming recognizers (Apple Speech)

    @Test func streamingFinalReusesTheVolatileTranslation() async {
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: translator)

        await pipeline.submitVolatile("Where have you been?")
        await pipeline.flush()
        await pipeline.submitFinal("Where have you been?", speechEndedAt: Date())
        await pipeline.flush()

        #expect(await translator.calls == ["Where have you been?"])
        #expect(lines(updates).map(\.translation) == ["[my] Where have you been?"])
        #expect(updates.values.contains(.draft(DraftCaption(text: "[my] Where have you been?", isTranslation: true))))
    }

    @Test func finishedSentencesAreNotTranslatedTwice() async {
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: translator)

        await pipeline.submitVolatile("I waited. Nobody")
        await pipeline.flush()
        await pipeline.submitFinal("I waited. Nobody came.", speechEndedAt: Date())
        await pipeline.flush()

        #expect(await translator.calls.filter { $0 == "I waited." }.count == 1)
        #expect(lines(updates).map(\.translation) == ["[my] I waited. [my] Nobody came."])
    }

    @Test func streamingTranscribeOnlyShowsWordsAsTheyArrive() async {
        let (pipeline, updates) = pipeline(
            transcriber: FakeTranscriber(script: [:]), translator: PassthroughTranslator(), target: nil, translateDrafts: false)

        await pipeline.submitVolatile("Hello")
        await pipeline.submitFinal("Hello there.", speechEndedAt: Date())
        await pipeline.flush()

        #expect(updates.values.first == .draft(DraftCaption(text: "Hello", isTranslation: false)))
        #expect(lines(updates).map(\.translation) == ["Hello there."])
    }

    @Test func sentencesAreSplitOnEndPunctuation() {
        #expect(SubtitlePipeline.sentences(in: "Where were you? I waited. Call me!")
            == ["Where were you?", "I waited.", "Call me!"])
        #expect(SubtitlePipeline.sentences(in: "It costs 3.5 dollars.") == ["It costs 3.5 dollars."])
        #expect(SubtitlePipeline.sentences(in: "Mr. Kim is here. Hi.") == ["Mr. Kim is here.", "Hi."])
        #expect(SubtitlePipeline.sentences(in: "你好。我很好。") == ["你好。", "我很好。"])
        #expect(SubtitlePipeline.sentences(in: "no punctuation at all") == ["no punctuation at all"])
    }

    @Test func translationIsDoneSentenceBySentence() async throws {
        let translator = FakeTranslator()
        let result = try await SubtitlePipeline.translate(
            "First one. Second one.", from: "en", to: "my", context: [], with: translator)
        #expect(await translator.calls == ["First one.", "Second one."])
        #expect(result == "[my] First one. [my] Second one.")
    }
}
