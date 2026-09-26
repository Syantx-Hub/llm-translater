import Foundation

/// Splits a live 16 kHz stream into utterances with an energy-based VAD.
///
/// While someone is speaking it emits `.partial` with the utterance so far (for grey draft
/// text), and `.final` once they pause or the utterance hits `maxSeconds`. Only speech is
/// passed on, which keeps Whisper from hallucinating on silence.
///
/// Not thread-safe: call `append` from one queue.
final class SpeechSegmenter {
    enum Event {
        case partial([Float])
        /// `trailingSilence`: samples of silence at the end. A draft of the first
        /// `count - trailingSilence` samples already heard every word.
        case final([Float], trailingSilence: Int)
    }

    /// Trade-off between how soon a line appears and how much context Whisper gets.
    struct Tuning: Equatable {
        /// Silence that ends an utterance.
        var endSilenceMS: Int
        /// New speech between draft updates.
        var draftEveryMS: Int
        /// Longest utterance before it is cut at the quietest point.
        var maxSeconds: Double

        static let fast = Tuning(endSilenceMS: 360, draftEveryMS: 500, maxSeconds: 6)
        static let balanced = Tuning(endSilenceMS: 480, draftEveryMS: 700, maxSeconds: 9)
        static let accurate = Tuning(endSilenceMS: 700, draftEveryMS: 1000, maxSeconds: 14)
    }

    var onEvent: ((Event) -> Void)?

    private let sampleRate = Int(SystemAudioCapture.sampleRate)
    private let frameSize = 480 // 30 ms
    private let preRollFrames = 10 // keep 300 ms before speech onset
    private let minSpeechFrames = 8 // ignore blips shorter than 240 ms
    private let pauseDraftFrames = 4 // a 120 ms pause triggers a draft of everything said
    private let endSilenceFrames: Int
    private let partialEverySamples: Int
    private let maxSeconds: Double

    init(tuning: Tuning = .balanced) {
        endSilenceFrames = max(1, tuning.endSilenceMS / 30)
        partialEverySamples = tuning.draftEveryMS * 16
        maxSeconds = tuning.maxSeconds
    }

    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var frameEnergies: [Float] = []
    private var inSpeech = false
    private var speechFrames = 0
    private var silenceFrames = 0
    private var samplesSincePartial = 0
    private var noiseFloor: Float = 1e-4

    func append(_ samples: [Float]) {
        pending += samples
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            process(frame)
        }
    }

    func reset() {
        pending.removeAll()
        preRoll.removeAll()
        endUtterance(emit: false)
    }

    private func process(_ frame: [Float]) {
        let energy = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        let isSpeech = energy > max(noiseFloor * 6, 2e-5)

        if !inSpeech {
            // Track the background level slowly, so steady music raises the threshold.
            noiseFloor = noiseFloor * 0.98 + energy * 0.02
            preRoll.append(frame)
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            guard isSpeech else { return }
            inSpeech = true
            utterance = preRoll.flatMap { $0 }
            frameEnergies = preRoll.map { $0.reduce(0) { $0 + $1 * $1 } / Float($0.count) }
            preRoll.removeAll()
        }

        utterance += frame
        frameEnergies.append(energy)
        samplesSincePartial += frame.count
        if isSpeech {
            speechFrames += 1
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }

        if silenceFrames >= endSilenceFrames {
            endUtterance(emit: speechFrames >= minSpeechFrames)
        } else if silenceFrames == pauseDraftFrames, speechFrames >= minSpeechFrames {
            // Draft right as the speaker pauses: if the pause turns into the end of the
            // utterance, the pipeline reuses this draft instead of decoding again.
            samplesSincePartial = 0
            onEvent?(.partial(utterance))
        } else if Double(utterance.count) >= maxSeconds * Double(sampleRate) {
            splitAtQuietestFrame()
        } else if samplesSincePartial >= partialEverySamples, speechFrames >= minSpeechFrames {
            samplesSincePartial = 0
            onEvent?(.partial(utterance))
        }
    }

    /// Long speech with no pause (or speech over music): cut at the quietest frame in
    /// the last 3 s rather than mid-word, and carry the remainder into the next utterance.
    private func splitAtQuietestFrame() {
        let window = min(frameEnergies.count, 3 * sampleRate / frameSize)
        let start = frameEnergies.count - window
        let quietest = frameEnergies[start...].indices.min { frameEnergies[$0] < frameEnergies[$1] } ?? frameEnergies.count
        let cut = max(quietest, 1) * frameSize

        onEvent?(.final(Array(utterance.prefix(cut)), trailingSilence: 0))
        utterance = Array(utterance.dropFirst(cut))
        frameEnergies = Array(frameEnergies.dropFirst(quietest))
        samplesSincePartial = utterance.count
        speechFrames = frameEnergies.count
        silenceFrames = 0
    }

    private func endUtterance(emit: Bool) {
        if emit { onEvent?(.final(utterance, trailingSilence: silenceFrames * frameSize)) }
        utterance.removeAll()
        frameEnergies.removeAll()
        inSpeech = false
        speechFrames = 0
        silenceFrames = 0
        samplesSincePartial = 0
    }
}
