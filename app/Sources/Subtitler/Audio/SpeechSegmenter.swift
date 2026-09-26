import Foundation

/// Splits a live 16 kHz stream into utterances, using a voice-activity detector (Silero)
/// or, without one, frame energy against an adaptive noise floor.
///
/// While someone is speaking it emits `.partial` with the utterance so far (for grey draft
/// text), and `.final` once they pause or the utterance hits `maxSeconds`. Only speech is
/// passed on, which keeps Whisper from hallucinating on silence.
///
/// Not thread-safe: call `append` from one queue.
final class SpeechSegmenter {
    enum Event {
        /// `isPause`: sent the moment the speaker pauses, covering everything said so far.
        case partial([Float], isPause: Bool)
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
    private let detector: SpeechDetector?
    private let frameSize: Int
    private let preRollFrames: Int // keep ~300 ms before speech onset
    private let minSpeechFrames: Int // ignore blips shorter than ~240 ms
    private let pauseDraftFrames: Int // a ~120 ms pause triggers a draft of everything said
    private let endSilenceFrames: Int
    private let partialEverySamples: Int
    private let maxSeconds: Double

    /// - Parameter detector: decides speech per frame; nil uses frame energy (30 ms frames).
    init(tuning: Tuning = .balanced, detector: SpeechDetector? = nil) {
        self.detector = detector
        frameSize = detector?.frameSize ?? 480
        let frameMS = Double(frameSize) / 16
        func frames(_ ms: Double) -> Int { max(1, Int((ms / frameMS).rounded())) }
        preRollFrames = frames(300)
        minSpeechFrames = frames(240)
        pauseDraftFrames = frames(120)
        endSilenceFrames = frames(Double(tuning.endSilenceMS))
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
    /// Recent frame energies (~3 s), to notice background sound that never goes quiet.
    private var recentEnergies: [Float] = []

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
        detector?.reset()
        endUtterance(emit: false)
    }

    private func process(_ frame: [Float]) {
        let energy = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        recentEnergies.append(energy)
        if recentEnergies.count > 100 { recentEnergies.removeFirst() }
        if inSpeech, recentEnergies.count == 100, let quietest = recentEnergies.min(), quietest > noiseFloor * 6 {
            // Speech has gaps between words; sound that stayed loud for 3 s straight is a
            // music bed or ambience. Let the floor rise to it so the utterance can end.
            noiseFloor = noiseFloor * 0.9 + quietest * 0.1
        }
        let isSpeech = detector?.isSpeech(frame) ?? (energy > max(noiseFloor * 6, 2e-5))

        if !inSpeech {
            // Track the background level slowly, so steady music raises the threshold.
            noiseFloor = noiseFloor * 0.98 + energy * 0.02
            guard isSpeech else {
                preRoll.append(frame)
                if preRoll.count > preRollFrames { preRoll.removeFirst() }
                return
            }
            // The onset frame itself is appended below, after the pre-roll.
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
            onEvent?(.partial(utterance, isPause: true))
        } else if Double(utterance.count) >= maxSeconds * Double(sampleRate) {
            splitAtQuietestFrame()
        } else if samplesSincePartial >= partialEverySamples, speechFrames >= minSpeechFrames {
            samplesSincePartial = 0
            onEvent?(.partial(utterance, isPause: false))
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
