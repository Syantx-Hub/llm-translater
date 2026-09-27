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
        updates.values.compactMap { if case .line(let o, let t, _, _) = $0 { (o, t) } else { nil } }
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

    // MARK: Changing language mid-session (auto-detect)

    @Test func autoDetectSwitchesWhenTheLanguageChanges() async {
        let long = 30_000 // enough audio to trust a language guess
        let transcriber = FakeTranscriber(script: [long: "Hello.", long + 1: "Hi.", long + 2: "Hallo.", long + 3: "Guten Tag."])
        await transcriber.setSpoken([long + 2: "de", long + 3: "de"])
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: nil, translateDrafts: false)

        for count in long...(long + 3) {
            await pipeline.submit(.final(samples(count), trailingSilence: 0))
        }
        await pipeline.flush()

        let detected = updates.values.compactMap { if case .detectedLanguage(let code) = $0 { code } else { nil } }
        #expect(detected == ["en", "de"])
    }

    @Test func oneLineInAnotherLanguageDoesNotSwitch() async {
        let long = 30_000
        let transcriber = FakeTranscriber(script: [long: "Hello.", long + 1: "Merci.", long + 2: "Thanks."])
        await transcriber.setSpoken([long + 1: "fr"])
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: nil, translateDrafts: false)

        for count in long...(long + 2) {
            await pipeline.submit(.final(samples(count), trailingSilence: 0))
        }
        await pipeline.flush()

        let detected = updates.values.compactMap { if case .detectedLanguage(let code) = $0 { code } else { nil } }
        #expect(detected == ["en"])
    }

    @Test func aChosenLanguageNeverSwitches() async {
        let long = 30_000
        let transcriber = FakeTranscriber(script: [long: "Hallo.", long + 1: "Guten Tag."])
        await transcriber.setSpoken([long: "de", long + 1: "de"])
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: "en", translateDrafts: false)

        await pipeline.submit(.final(samples(long), trailingSilence: 0))
        await pipeline.submit(.final(samples(long + 1), trailingSilence: 0))
        await pipeline.flush()

        #expect(!updates.values.contains { if case .detectedLanguage = $0 { true } else { false } })
    }

    /// While Apple Speech transcribes, Whisper only samples the language.
    @Test func languageWatchOnlyDetectsWhileAnotherRecognizerTranscribes() async {
        let long = 30_000
        let transcriber = FakeTranscriber(script: [long: "Hello."])
        let (pipeline, updates) = pipeline(transcriber: transcriber, source: nil, translateDrafts: false)
        await pipeline.submit(.final(samples(long), trailingSilence: 0)) // locks English
        await pipeline.flush()

        await transcriber.setSpoken([long + 1: "de", long + 2: "de"])
        await pipeline.setWhisperTranscribes(false)
        await pipeline.submit(.final(samples(long + 1), trailingSilence: 0))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.flush()

        #expect(await transcriber.calls == [long]) // nothing transcribed after the hand-off
        #expect(await transcriber.detections == [long + 1])
        // One check isn't enough to switch; checks are also spaced out, so no switch yet.
        let detected = updates.values.compactMap { if case .detectedLanguage(let code) = $0 { code } else { nil } }
        #expect(detected == ["en"])
    }

    // MARK: Unclear lines and context

    @Test func unclearLinesAreHiddenInsteadOfTranslated() async {
        let transcriber = FakeTranscriber(script: [100: "Clear line.", 200: "Mumbled wrods."])
        await transcriber.setConfidences([100: 0.9, 200: 0.2])
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator, translateDrafts: false)

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.submit(.final(samples(200), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).map(\.original) == ["Clear line."])
        #expect(await translator.calls == ["Clear line."])
        #expect(updates.values.contains(.unclear("Mumbled wrods.")))
    }

    @Test func unclearLinesShowWhenFilteringIsOff() async {
        let transcriber = FakeTranscriber(script: [200: "Mumbled wrods."])
        await transcriber.setConfidences([200: 0.2])
        let updates = Recorder<SubtitlePipeline.Update>()
        let pipeline = SubtitlePipeline(transcriber: transcriber, translator: FakeTranslator(), source: "en", target: "my",
                                        translateDrafts: false, hidesUnclearLines: false) { updates.append($0) }

        await pipeline.submit(.final(samples(200), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).map(\.original) == ["Mumbled wrods."])
    }

    @Test func aSentenceCutByAPauseIsTranslatedWhole() async {
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: translator,
                                           translateDrafts: false)

        await pipeline.submitFinal("I told him that", speechEndedAt: Date())
        await pipeline.submitFinal("he was late.", speechEndedAt: Date())
        await pipeline.flush()

        #expect(lines(updates).map(\.original) == ["I told him that he was late."])
        #expect(await translator.calls == ["I told him that he was late."])
    }

    @Test func aFragmentNobodyFinishesShowsAfterAQuietMoment() async throws {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translateDrafts: false)

        await pipeline.submitFinal("Wait for me", speechEndedAt: Date())
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines(updates).isEmpty)
        try await Task.sleep(for: .seconds(SubtitlePipeline.joinWindow + 0.5))
        #expect(lines(updates).map(\.original) == ["Wait for me"])
    }

    @Test func transcribingNeverHoldsLines() async throws {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), target: nil)
        await pipeline.submitFinal("Wait for me", speechEndedAt: Date())
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines(updates).map(\.original) == ["Wait for me"])
    }

    @Test func fragmentsAndJoins() {
        #expect(SubtitlePipeline.isFragment("I told him that"))
        #expect(SubtitlePipeline.isFragment("If you go,"))
        #expect(!SubtitlePipeline.isFragment("He was late."))
        #expect(!SubtitlePipeline.isFragment("Where were you?"))
        #expect(!SubtitlePipeline.isFragment("So…"))
        #expect(!SubtitlePipeline.isFragment(String(repeating: "word ", count: 25)))
        // Recognizers put a full stop on every piece; a dangling last word gives it away.
        #expect(SubtitlePipeline.isFragment("Frank, I told you that.", language: "en"))
        #expect(!SubtitlePipeline.isFragment("Frank, I told you that.", language: "ko"))
        #expect(!SubtitlePipeline.isFragment("I love you.", language: "en"))
        #expect(!SubtitlePipeline.isFragment("Wait...", language: "en"))
        #expect(SubtitlePipeline.join("I told Frank,", "Frank was late.") == "I told Frank, Frank was late.")
        #expect(SubtitlePipeline.join(" ", "Hi.") == "Hi.")
        #expect(SubtitlePipeline.withoutFalseStop("I told you that.") == "I told you that")
        #expect(SubtitlePipeline.withoutFalseStop("I love you.") == "I love you.")
    }

    @Test func anLLMGetsTheWholeLineAtOnce() async {
        let (llm, llmUpdates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: FakeBatchTranslator(),
                                         translateDrafts: false)
        await llm.submitFinal("I know. Go home.", speechEndedAt: Date())
        await llm.flush()
        #expect(lines(llmUpdates).map(\.translation) == ["[my] I know. Go home."])

        let (mt, mtUpdates) = pipeline(transcriber: FakeTranscriber(script: [:]), translateDrafts: false)
        await mt.submitFinal("I know. Go home.", speechEndedAt: Date())
        await mt.flush()
        #expect(lines(mtUpdates).map(\.translation) == ["[my] I know. [my] Go home."])
    }

    @Test func unclearStreamingPhrasesAreHidden() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translateDrafts: false)

        await pipeline.submitFinal("Probably misheard.", speechEndedAt: Date(), confidence: 0.1)
        await pipeline.submitFinal("Clearly heard.", speechEndedAt: Date(), confidence: 0.95)
        await pipeline.flush()

        #expect(lines(updates).map(\.original) == ["Clearly heard."])
    }

    @Test func translateModeSkipsDraftsWhileSomeoneSpeaks() async {
        let transcriber = FakeTranscriber(script: [500: "Where", 900: "Where have you been?"])
        let (pipeline, _) = pipeline(transcriber: transcriber)

        await pipeline.submit(.partial(samples(500), isPause: false))
        await pipeline.submit(.partial(samples(900), isPause: true))
        await pipeline.flush()

        #expect(await transcriber.calls == [900]) // only the pause draft is decoded
    }

    @Test func silentFinalClearsTheDraftAndAddsNoLine() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]))

        await pipeline.submit(.final(samples(100), trailingSilence: 0))
        await pipeline.flush()

        #expect(lines(updates).isEmpty)
        #expect(updates.values.contains(.draft(nil)))
    }

    /// Translate mode shows finished lines only, but translates finished sentences in the
    /// background while someone speaks so the line is ready sooner.
    @Test func finishedSentencesAreTranslatedInTheBackground() async {
        let transcriber = FakeTranscriber(script: [1000: "Where have you been?"])
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: transcriber, translator: translator)

        await pipeline.submit(.partial(samples(1000), isPause: true))
        await pipeline.flush()

        #expect(await translator.calls == ["Where have you been?"])
        #expect(updates.values.isEmpty)
    }

    /// Word order differs between languages, so half a sentence is never translated, and
    /// the live line doesn't flash words in the original language meanwhile.
    @Test func unfinishedWordsAreNeitherTranslatedNorShown() async {
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: translator)

        await pipeline.submitVolatile("Where have you")
        await pipeline.flush()

        #expect(await translator.calls.isEmpty)
        #expect(updates.values.isEmpty)
    }

    @Test func translateModeNeverShowsLiveWords() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]))

        await pipeline.submitVolatile("When we got home,")
        await pipeline.submitVolatile("When we got home, nobody answered")
        await pipeline.flush()

        #expect(!updates.values.contains { if case .draft(let d?) = $0 { !d.text.isEmpty } else { false } })
    }

    @Test func transcribeModeShowsWordsAsTheyArrive() async {
        let (pipeline, updates) = pipeline(
            transcriber: FakeTranscriber(script: [:]), translator: PassthroughTranslator(), target: nil, translateDrafts: false)

        await pipeline.submitVolatile("Where have you")
        await pipeline.flush()

        #expect(updates.values == [.draft(DraftCaption(text: "Where have you", isTranslation: false))])
    }

    @Test func stableSplitFindsFinishedSentencesAndClauses() {
        #expect(SubtitlePipeline.stableSplit("Where have you") == ("", "Where have you"))
        #expect(SubtitlePipeline.stableSplit("I waited. Nobody") == ("I waited.", "Nobody"))
        #expect(SubtitlePipeline.stableSplit("Don't worry, my brother will") == ("", "Don't worry, my brother will"))
        #expect(SubtitlePipeline.stableSplit("When we got home, nobody was") == ("When we got home,", "nobody was"))
        #expect(SubtitlePipeline.stableSplit("It costs 3.5 dollars") == ("", "It costs 3.5 dollars"))
        #expect(SubtitlePipeline.stableSplit("你好。我很") == ("你好。", "我很"))
        #expect(SubtitlePipeline.stableSplit("Where have you been?") == ("Where have you been?", ""))
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
    }

    @Test func finishedSentencesAreNotTranslatedTwice() async {
        let translator = FakeTranslator()
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translator: translator)

        await pipeline.submitVolatile("I waited. Nobody")
        await pipeline.flush()
        await pipeline.submitFinal("I waited. Nobody came.", speechEndedAt: Date())
        await pipeline.flush()

        #expect(await translator.calls.filter { $0 == "I waited." }.count == 1)
        #expect(lines(updates).map(\.translation) == ["[my] I waited.", "[my] Nobody came."])
    }

    @Test func finishedSentencesBecomeLinesBeforeTheLongPhraseEnds() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translateDrafts: false)

        await pipeline.submitVolatile("Where were you? I waited")
        await pipeline.flush()
        #expect(lines(updates).map(\.original) == ["Where were you?"])

        await pipeline.submitFinal("Where were you? I waited for you.", speechEndedAt: Date())
        await pipeline.flush()
        // The final only adds what wasn't shown yet.
        #expect(lines(updates).map(\.original) == ["Where were you?", "I waited for you."])
    }

    /// Apple Speech waits for silence before finalizing, which background sound delays.
    @Test func aPunctuatedSentenceShowsWithoutWaitingForTheFinal() async {
        let (pipeline, updates) = pipeline(transcriber: FakeTranscriber(script: [:]), translateDrafts: false)

        await pipeline.submitVolatile("Where have you been")
        await pipeline.submitVolatile("Where have you been all night?")
        await pipeline.flush()
        #expect(lines(updates).map(\.original) == ["Where have you been all night?"])

        // The final arrives later and adds nothing new.
        await pipeline.submitFinal("Where have you been all night?", speechEndedAt: Date())
        await pipeline.flush()
        #expect(lines(updates).count == 1)
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
