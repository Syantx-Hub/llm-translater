import Foundation
@testable import Subtitler

enum Audio {
    static let rate = Int(SystemAudioCapture.sampleRate)

    static func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }
}

/// Collects values from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Transcribes by sample count, so a test controls what each segment "says".
actor FakeTranscriber: SpeechTranscribing {
    private let script: [Int: String]
    private let language: String
    private let delay: Duration?
    private(set) var calls: [Int] = []

    init(script: [Int: String], language: String = "en", delay: Duration? = nil) {
        self.script = script
        self.language = language
        self.delay = delay
    }

    /// Per sample count: the language actually spoken, when it isn't the default.
    var spoken: [Int: String] = [:]
    private(set) var detections: [Int] = []

    func setSpoken(_ languages: [Int: String]) { spoken = languages }

    /// Per sample count: how sure the "recognizer" is.
    var confidences: [Int: Double] = [:]
    private(set) var prompts: [String?] = []

    func setConfidences(_ values: [Int: Double]) { confidences = values }

    func transcribe(_ samples: [Float], language requested: String?, prompt: String?) async throws -> Transcript? {
        calls.append(samples.count)
        prompts.append(prompt)
        if let delay { try await Task.sleep(for: delay) }
        guard let text = script[samples.count] else { return nil }
        // Like Whisper: a forced language is used as is; otherwise the spoken one is detected.
        return Transcript(text: text, language: requested ?? spoken[samples.count] ?? language,
                          confidence: confidences[samples.count])
    }

    func detectLanguage(_ samples: [Float]) async throws -> String? {
        detections.append(samples.count)
        return spoken[samples.count] ?? language
    }
}

/// Prefixes the target language; can be slowed down or made to fail per input.
actor FakeTranslator: Translator {
    private let delays: [String: Duration]
    private let failing: Set<String>
    private(set) var calls: [String] = []

    init(delays: [String: Duration] = [:], failing: Set<String> = []) {
        self.delays = delays
        self.failing = failing
    }

    struct Failure: Error {}

    func start() async throws {}
    func stop() async {}

    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        calls.append(text)
        if let delay = delays[text] { try await Task.sleep(for: delay) }
        if failing.contains(text) { throw Failure() }
        return "[\(target)] \(text)"
    }
}

/// A fresh, isolated UserDefaults suite for one test.
func makeDefaults() -> UserDefaults {
    let name = "subtitler.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitler-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Repo root, derived from this file's location (app/Tests/SubtitlerTests/...).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
