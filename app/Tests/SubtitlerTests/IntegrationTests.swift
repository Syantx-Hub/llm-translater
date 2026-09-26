import Foundation
import Testing
@testable import Subtitler

/// Tests that cross process or framework boundaries: the Python sidecar protocol, audio
/// file decoding, and (opt-in, `SUBTITLER_E2E=1`) the full pipeline with real models.
@Suite struct IntegrationTests {
    private var echoSidecar: SidecarTranslator {
        SidecarTranslator(
            location: SidecarLocation(
                python: URL(fileURLWithPath: "/usr/bin/python3"),
                script: repoRoot.appendingPathComponent("python/translate_server.py"),
                repoRoot: repoRoot),
            engine: .echo)
    }

    @Test(.timeLimit(.minutes(1))) func sidecarRoundTripsOverJSONLines() async throws {
        let sidecar = echoSidecar
        try await sidecar.start()
        let first = try await sidecar.translate("Hello there", from: "en", to: "my", context: [])
        let unicode = try await sidecar.translate("မင်္ဂလာပါ", from: "my", to: "en", context: ["previous line"])
        await sidecar.stop()
        #expect(first == "Hello there")
        #expect(unicode == "မင်္ဂလာပါ")
    }

    @Test(.timeLimit(.minutes(1))) func sidecarReportsUnsupportedLanguages() async throws {
        let sidecar = echoSidecar
        try await sidecar.start()
        await #expect(throws: SidecarError.self) {
            _ = try await sidecar.translate("x", from: "xx", to: "my", context: [])
        }
        // A bad request must not kill the sidecar.
        let after = try await sidecar.translate("still alive", from: "en", to: "my", context: [])
        #expect(after == "still alive")
        await sidecar.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stoppedSidecarRejectsRequests() async throws {
        let sidecar = echoSidecar
        try await sidecar.start()
        await sidecar.stop()
        await #expect(throws: (any Error).self) {
            _ = try await sidecar.translate("late", from: "en", to: "my", context: [])
        }
    }

    @Test func missingSidecarFailsToStart() async {
        let sidecar = SidecarTranslator(
            location: SidecarLocation(
                python: URL(fileURLWithPath: "/nonexistent/python"),
                script: repoRoot.appendingPathComponent("python/translate_server.py"), repoRoot: repoRoot),
            engine: .echo)
        await #expect(throws: SidecarError.self) { try await sidecar.start() }
    }

    @Test func audioFilesDecodeTo16kMono() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "Testing one two three."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let samples = try FileRunner.loadAudio(url)
        let seconds = Double(samples.count) / SystemAudioCapture.sampleRate
        #expect(seconds > 0.8 && seconds < 5)
        #expect(samples.contains { abs($0) > 0.01 })
    }

    @Test func translatorFactoryHonoursSelections() throws {
        #expect(try TranslatorFactory.make(selection: ModelStore.translationOff) is PassthroughTranslator)
        #expect(throws: TranslatorSelectionError.self) {
            _ = try TranslatorFactory.make(selection: "no-such-model")
        }
    }

    /// Full pipeline with the installed speech and translation models. Slow; opt-in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBTITLER_E2E"] == "1"), .timeLimit(.minutes(10)))
    func endToEndEnglishToBurmese() async throws {
        let speech = try #require(ModelCatalog.speech.first(where: ModelFiles.isInstalled), "no speech model installed")
        let translation = try #require(ModelCatalog.translation.first(where: ModelFiles.isInstalled), "no translation model")

        let url = try makeTemporaryDirectory().appendingPathComponent("e2e.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "I was waiting for you at the station."]
        try say.run()
        say.waitUntilExit()

        let transcriber = Transcriber()
        try await transcriber.load(model: speech.id, folder: ModelFiles.localURL(for: speech))
        let translator = try TranslatorFactory.make(selection: translation.id)
        try await translator.start()

        let updates = Recorder<SubtitlePipeline.Update>()
        let pipeline = SubtitlePipeline(transcriber: transcriber, translator: translator, source: "en", target: "my") {
            updates.append($0)
        }
        let segmenter = SpeechSegmenter()
        let events = Recorder<SpeechSegmenter.Event>()
        segmenter.onEvent = { events.append($0) }
        segmenter.append(try FileRunner.loadAudio(url) + Audio.silence(1))
        for event in events.values { await pipeline.submit(event) }
        await pipeline.flush()
        await translator.stop()

        let line = try #require(updates.values.compactMap { update -> (String, String)? in
            if case .line(let o, let t, _) = update { (o, t) } else { nil }
        }.first)
        #expect(line.0.lowercased().contains("station"))
        // Output must be Unicode Burmese (U+1000–U+109F).
        #expect(line.1.unicodeScalars.contains { (0x1000...0x109F).contains($0.value) })
    }
}
