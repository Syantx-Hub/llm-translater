import Foundation
import OnnxRuntimeBindings

/// Decides, 32 ms at a time, whether someone is speaking.
protocol SpeechDetector: AnyObject {
    /// Samples per call (16 kHz).
    var frameSize: Int { get }
    func isSpeech(_ frame: [Float]) -> Bool
    func reset()
}

/// Silero VAD (MIT, github.com/snakers4/silero-vad), a small neural voice-activity
/// model. Unlike an energy threshold it tells speech from music, effects and crowd noise,
/// so utterances end on time in films, where there's rarely real silence.
final class SileroVAD: SpeechDetector {
    let frameSize = 512
    /// Silero keeps the last 64 samples of the previous frame as context.
    private let contextSize = 64
    /// Speech starts above `onThreshold` and ends below `offThreshold` (hysteresis).
    private let onThreshold: Float = 0.5
    private let offThreshold: Float = 0.35

    private let env: ORTEnv
    private let session: ORTSession
    private var state = [Float](repeating: 0, count: 2 * 128)
    private var context: [Float]
    private var speaking = false

    /// nil if the bundled model can't be loaded (the caller falls back to energy VAD).
    init?() {
        guard let url = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx"),
              let env = try? ORTEnv(loggingLevel: .warning)
        else { return nil }
        let options = try? ORTSessionOptions()
        try? options?.setIntraOpNumThreads(1)
        guard let session = try? ORTSession(env: env, modelPath: url.path, sessionOptions: options) else { return nil }
        self.env = env
        self.session = session
        context = [Float](repeating: 0, count: contextSize)
    }

    /// Speech probability of one 512-sample frame, 0–1.
    func probability(_ frame: [Float]) -> Float {
        let input = context + frame
        guard let inputValue = Self.tensor(input, shape: [1, NSNumber(value: input.count)]),
              let stateValue = Self.tensor(state, shape: [2, 1, 128]),
              let rate = try? ORTValue(tensorData: NSMutableData(bytes: [Int64(16_000)], length: 8),
                                       elementType: .int64, shape: []),
              let outputs = try? session.run(withInputs: ["input": inputValue, "state": stateValue, "sr": rate],
                                             outputNames: ["output", "stateN"], runOptions: nil),
              let probability = outputs["output"].flatMap(Self.floats)?.first,
              let newState = outputs["stateN"].flatMap(Self.floats), newState.count == state.count
        else { return 0 }
        state = newState
        context = Array(input.suffix(contextSize))
        return probability
    }

    func isSpeech(_ frame: [Float]) -> Bool {
        let p = probability(frame)
        if speaking, p < offThreshold { speaking = false } else if !speaking, p > onThreshold { speaking = true }
        return speaking
    }

    func reset() {
        state = [Float](repeating: 0, count: state.count)
        context = [Float](repeating: 0, count: contextSize)
        speaking = false
    }

    private static func tensor(_ values: [Float], shape: [NSNumber]) -> ORTValue? {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
        return try? ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    private static func floats(_ value: ORTValue) -> [Float]? {
        guard let data = try? value.tensorData() else { return nil }
        return [Float](unsafeUninitializedCapacity: data.length / 4) { buffer, count in
            data.getBytes(buffer.baseAddress!, length: data.length)
            count = data.length / 4
        }
    }
}
