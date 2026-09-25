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
        case final([Float])
    }

    var onEvent: ((Event) -> Void)?

    private let sampleRate = Int(SystemAudioCapture.sampleRate)
    private let frameSize = 480 // 30 ms
    private let preRollFrames = 10 // keep 300 ms before speech onset
    private let endSilenceFrames = 20 // 600 ms of silence ends an utterance
    private let minSpeechFrames = 8 // ignore blips shorter than 240 ms
    private let partialEverySamples = 16_000 // draft update every 1 s of new speech
    private let maxSeconds = 12.0

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

        onEvent?(.final(Array(utterance.prefix(cut))))
        utterance = Array(utterance.dropFirst(cut))
        frameEnergies = Array(frameEnergies.dropFirst(quietest))
        samplesSincePartial = utterance.count
        speechFrames = frameEnergies.count
        silenceFrames = 0
    }

    private func endUtterance(emit: Bool) {
        if emit { onEvent?(.final(utterance)) }
        utterance.removeAll()
        frameEnergies.removeAll()
        inSpeech = false
        speechFrames = 0
        silenceFrames = 0
        samplesSincePartial = 0
    }
}
