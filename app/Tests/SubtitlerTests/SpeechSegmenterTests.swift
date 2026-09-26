import Testing
@testable import Subtitler

@Suite struct SpeechSegmenterTests {
    private let frame = 480

    private func run(_ samples: [Float], tuning: SpeechSegmenter.Tuning = .balanced) -> [SpeechSegmenter.Event] {
        let segmenter = SpeechSegmenter(tuning: tuning)
        var events: [SpeechSegmenter.Event] = []
        segmenter.onEvent = { events.append($0) }
        // Feed in 100 ms chunks, like the capture callbacks.
        for start in stride(from: 0, to: samples.count, by: 1600) {
            segmenter.append(Array(samples[start..<min(start + 1600, samples.count)]))
        }
        return events
    }

    private func finals(_ events: [SpeechSegmenter.Event]) -> [(samples: [Float], trailing: Int)] {
        events.compactMap { if case .final(let s, let t) = $0 { (s, t) } else { nil } }
    }

    private func partials(_ events: [SpeechSegmenter.Event]) -> [[Float]] {
        events.compactMap { if case .partial(let s, _) = $0 { s } else { nil } }
    }

    @Test func silenceProducesNothing() {
        #expect(run(Audio.silence(3)).isEmpty)
    }

    @Test func shortBlipIsIgnored() {
        #expect(finals(run(Audio.silence(0.5) + Audio.tone(0.15) + Audio.silence(1.5))).isEmpty)
    }

    @Test func speechThenPauseProducesOneFinal() throws {
        let events = run(Audio.silence(0.5) + Audio.tone(1) + Audio.silence(1.5))
        let result = finals(events)
        try #require(result.count == 1)
        let final = result[0]
        // Balanced ends utterances after 480 ms (16 frames) of silence.
        #expect(final.trailing == 16 * frame)
        // Speech (1 s, rounded to frames) plus 300 ms pre-roll plus the trailing silence —
        // and the onset frame counted once, not twice.
        let speech = final.samples.count - final.trailing - 10 * frame
        #expect(abs(speech - Audio.rate) <= frame)
    }

    /// The latency optimisation depends on this: the draft sent when the speaker pauses
    /// must cover all speech, so the final can reuse it.
    @Test func pauseDraftCoversAllSpeechOfTheFinal() throws {
        let events = run(Audio.silence(0.5) + Audio.tone(1.2) + Audio.silence(1.5))
        let final = try #require(finals(events).first)
        let lastDraft = try #require(partials(events).last)
        let unheard = final.samples.count - lastDraft.count
        #expect(unheard >= 0)
        #expect(unheard <= final.trailing)
        #expect(Array(final.samples.prefix(lastDraft.count)) == lastDraft)
    }

    @Test func draftsGrowWhileSpeaking() {
        let drafts = partials(run(Audio.tone(3) + Audio.silence(1), tuning: .fast))
        #expect(drafts.count >= 4)
        #expect(zip(drafts, drafts.dropFirst()).allSatisfy { $0.count < $1.count })
    }

    /// Syllable-like bursts: loud for 200 ms, near-silent for 60 ms, like real speech.
    private func speechLike(_ seconds: Double) -> [Float] {
        var out: [Float] = []
        while Double(out.count) < seconds * Double(Audio.rate) {
            out += Audio.tone(0.2) + Audio.tone(0.06, amplitude: 0.002)
        }
        return Array(out.prefix(Int(seconds * Double(Audio.rate))))
    }

    @Test func steadyMusicStopsCountingAsSpeech() {
        // A constant tone never dips like speech does; after a few seconds it becomes the
        // background level and stops producing utterances.
        let events = run(Audio.tone(30))
        let finals = finals(events)
        let covered = finals.reduce(0) { $0 + $1.samples.count }
        #expect(!finals.isEmpty)
        #expect(covered < 20 * Audio.rate)
    }

    @Test func longSpeechIsSplitWithoutLosingAudio() throws {
        let input = speechLike(20) + Audio.silence(1.5)
        let result = finals(run(input))
        try #require(result.count >= 3)
        let limit = Int(SpeechSegmenter.Tuning.balanced.maxSeconds) * Audio.rate
        #expect(result.allSatisfy { !$0.samples.isEmpty && $0.samples.count <= limit })
        // Forced splits have no trailing silence, so their drafts are never reused.
        #expect(result.dropLast().allSatisfy { $0.trailing == 0 })
        // Every sample from the onset to the end of the last utterance is in exactly one final.
        let total = result.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - (20 * Audio.rate + 16 * frame)) <= frame)
    }

    @Test func fastPresetEndsUtterancesSooner() throws {
        let input = Audio.tone(1) + Audio.silence(1.5)
        let fast = try #require(finals(run(input, tuning: .fast)).first)
        let accurate = try #require(finals(run(input, tuning: .accurate)).first)
        #expect(fast.trailing < accurate.trailing)
    }
}
