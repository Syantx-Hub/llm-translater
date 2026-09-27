import Foundation
import WhisperKit

/// Everything the app can download. The app ships with no models; people pick and
/// download them in the Models window, and can swap at any time.
struct ModelInfo: Identifiable, Hashable {
    enum Kind: String {
        case speech, translation
    }

    enum Source: Hashable {
        /// A variant folder in argmaxinc/whisperkit-coreml, plus the OpenAI tokenizer it uses.
        case whisperKit(variant: String, tokenizer: ModelVariant)
        /// A single GGUF file run by llama.cpp.
        case gguf(url: URL, fileName: String)
        /// Built into macOS (Apple Speech); nothing to download or delete.
        case system
    }

    let id: String
    let kind: Kind
    let name: String
    let summary: String
    /// Short "why pick this" points shown on the card.
    let strengths: [String]
    let source: Source
    let sizeMB: Int
    /// 1–5, relative within the same kind.
    let speed: Int
    let quality: Int
    let license: String
    let commercialUse: Bool
    /// Below this the model will swap or fail to load.
    let minRAMGB: Int
    let englishOnly: Bool
    /// Enough memory to run it alongside speech recognition and a browser; nil when
    /// `minRAMGB` already is.
    var recommendedRAMGB: Int? = nil
    /// A chat LLM (Gemma) that follows instructions and translates in batches, rather
    /// than a translation model (MADLAD) that only takes the text.
    var isLLM = false

    var isBuiltIn: Bool { source == .system }

    /// How well this Mac's memory suits the model.
    enum Fit {
        /// At or above the recommended memory.
        case comfortable
        /// Loads, but with little to spare: other apps may slow it down.
        case tight
        /// Below the minimum: it will swap heavily or fail to load.
        case tooBig
    }

    var recommendedRAM: Int { max(recommendedRAMGB ?? minRAMGB, minRAMGB) }

    func fit(ramGB: Int = Hardware.ramGB) -> Fit {
        if ramGB < minRAMGB { return .tooBig }
        return ramGB < recommendedRAM ? .tight : .comfortable
    }

    var sizeLabel: String {
        if isBuiltIn { return "Built in" }
        return sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB"
    }
}

enum ModelCatalog {
    static let appleSpeechID = "apple-speech"

    /// Apple's streaming recognizer: words appear as they're spoken. macOS 26 and later,
    /// and only for the languages Apple supports; other languages fall back to Whisper.
    static let appleSpeech = ModelInfo(
        id: appleSpeechID, kind: .speech,
        name: "Apple Speech (instant)",
        summary: "Words appear as they're spoken. English, Korean, Japanese, Chinese, French, German, Spanish, Italian and Portuguese.",
        strengths: ["Lowest lag: captions keep up with the speaker", "Built into macOS — nothing to download"],
        source: .system,
        sizeMB: 0, speed: 5, quality: 4, license: "Apple", commercialUse: true, minRAMGB: 8, englishOnly: false)

    static let speech: [ModelInfo] = (AppleSpeech.isAvailable ? [appleSpeech] : []) + whisper

    static let fastTurboID = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static let whisper: [ModelInfo] = [
        ModelInfo(
            id: fastTurboID, kind: .speech,
            name: "Whisper Large v3 Turbo (fast)",
            summary: "Turbo with Argmax's streaming-optimised encoder: the same words, heard in about half the time.",
            strengths: ["Lowest lag with Whisper: ~0.6 s per line on an M2 (vs ~1 s)", "Works for every language and Auto-detect"],
            source: .whisperKit(variant: fastTurboID, tokenizer: .largev3),
            sizeMB: 632, speed: 5, quality: 5, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: false),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930", kind: .speech,
            name: "Whisper Large v3 Turbo",
            summary: "The best balance of accuracy and speed for live subtitles.",
            strengths: ["Strong on Korean, Japanese, Chinese and English", "Fast enough for real time on every M-series chip"],
            source: .whisperKit(variant: "openai_whisper-large-v3-v20240930", tokenizer: .largev3),
            sizeMB: 1620, speed: 4, quality: 5, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: false),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_626MB", kind: .speech,
            name: "Whisper Large v3 Turbo (compact)",
            summary: "Turbo compressed to a third of the size, with a small accuracy cost.",
            strengths: ["Leaves more memory for translation and other apps", "Good pick for 8 GB Macs that run a browser alongside"],
            source: .whisperKit(variant: "openai_whisper-large-v3-v20240930_626MB", tokenizer: .largev3),
            sizeMB: 627, speed: 4, quality: 4, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: false),
        ModelInfo(
            id: "openai_whisper-large-v3", kind: .speech,
            name: "Whisper Large v3",
            summary: "The most accurate model, at roughly half Turbo's speed.",
            strengths: ["Best with accents, noise and fast dialogue", "Pick it on Pro, Max or Ultra chips"],
            source: .whisperKit(variant: "openai_whisper-large-v3", tokenizer: .largev3),
            sizeMB: 3090, speed: 2, quality: 5, license: "MIT", commercialUse: true, minRAMGB: 16, englishOnly: false),
        ModelInfo(
            id: "openai_whisper-small", kind: .speech,
            name: "Whisper Small",
            summary: "Light and quick; fine for clear speech.",
            strengths: ["Low latency, low battery use", "Good for English and clear dialogue"],
            source: .whisperKit(variant: "openai_whisper-small", tokenizer: .small),
            sizeMB: 486, speed: 5, quality: 3, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: false),
        ModelInfo(
            id: "distil-whisper_distil-large-v3", kind: .speech,
            name: "Distil-Whisper Large v3 (English)",
            summary: "Near-Large accuracy for English at much higher speed.",
            strengths: ["Fastest high-accuracy option for English", "English audio only"],
            source: .whisperKit(variant: "distil-whisper_distil-large-v3", tokenizer: .largev3),
            sizeMB: 1515, speed: 5, quality: 4, license: "MIT", commercialUse: true, minRAMGB: 8, englishOnly: true),
    ]

    static let madlad: [ModelInfo] = [
        ModelInfo(
            id: "madlad400-3b-q4_k_m", kind: .translation,
            name: "MADLAD-400 3B",
            summary: "A translation model: fast, and takes each sentence on its own. Names, pronouns and tone can come out literal, because it never sees the lines around it.",
            strengths: ["Recommended for live Translate: the quickest to keep up with speech", "400+ languages, including rare ones Gemma handles less well"],
            source: .gguf(
                url: URL(string: "https://huggingface.co/hs-hf/madlad400-3b-mt-gguf/resolve/main/madlad400-3b-mt-q4_k_m.gguf")!,
                fileName: "madlad400-3b-mt-q4_k_m.gguf"),
            sizeMB: 1860, speed: 4, quality: 4, license: "Apache 2.0", commercialUse: true, minRAMGB: 8, englishOnly: false),
        ModelInfo(
            id: "madlad400-3b-q8_0", kind: .translation,
            name: "MADLAD-400 3B (high quality)",
            summary: "Same model at higher precision: slightly better wording, larger and slower.",
            strengths: ["Fewer awkward phrasings in long sentences", "Recommended with 16 GB or more"],
            source: .gguf(
                url: URL(string: "https://huggingface.co/hs-hf/madlad400-3b-mt-gguf/resolve/main/madlad400-3b-mt-q8_0.gguf")!,
                fileName: "madlad400-3b-mt-q8_0.gguf"),
            sizeMB: 3130, speed: 3, quality: 5, license: "Apache 2.0", commercialUse: true, minRAMGB: 16, englishOnly: false),
    ]

    /// Google's Gemma 4 chat models, 4-bit, run by llama.cpp. Unlike MADLAD they read the
    /// same instructions as the cloud LLMs: names, register, the cast sheet, earlier lines.
    /// Memory: the file loads into GPU memory, which macOS caps at about two thirds of RAM,
    /// plus room for the context and the speech model.
    static let gemma: [ModelInfo] = [
        gemma4("E2B", name: "Gemma 4 E2B", sizeMB: 2841, speed: 3, quality: 4, minRAMGB: 8, recommendedRAMGB: 8,
               summary: "A small AI model that reads the scene: earlier lines, the film's names, casual or polite speech. More natural dialogue than MADLAD, a little slower.",
               strengths: ["Recommended for watching movies: natural wording, names spelled the same all film", "Fits an 8 GB Mac"]),
        gemma4("E4B", name: "Gemma 4 E4B", sizeMB: 4590, speed: 3, quality: 4, minRAMGB: 8, recommendedRAMGB: 16,
               summary: "Twice E2B's working size: better wording and fewer mistakes, still light.",
               strengths: ["Best Gemma for 16 GB Macs", "Loads on 8 GB with other apps closed"]),
        gemma4("12B", name: "Gemma 4 12B", sizeMB: 7219, speed: 2, quality: 4, minRAMGB: 16, recommendedRAMGB: 24,
               summary: "A mid-size model with noticeably more natural phrasing in low-resource languages.",
               strengths: ["Stronger with idioms, slang and politeness levels", "Pick it on 24 GB or more"]),
        gemma4("26B-A4B", name: "Gemma 4 26B (MoE)", sizeMB: 14618, speed: 3, quality: 5, minRAMGB: 24, recommendedRAMGB: 32,
               summary: "A mixture-of-experts model: 26B parameters of knowledge, but only 4B work per word, so it's quick.",
               strengths: ["Near-31B quality at a fraction of the time", "Needs 24 GB; 32 GB recommended"]),
        gemma4("31B", name: "Gemma 4 31B", sizeMB: 17992, speed: 1, quality: 5, minRAMGB: 32, recommendedRAMGB: 48,
               summary: "The largest Gemma 4: the best local translation, and the slowest.",
               strengths: ["Closest to the cloud LLMs, fully offline", "For Max and Ultra chips with 32 GB or more"]),
    ]

    private static func gemma4(_ size: String, name: String, sizeMB: Int, speed: Int, quality: Int, minRAMGB: Int,
                               recommendedRAMGB: Int, summary: String, strengths: [String]) -> ModelInfo {
        let file = "gemma-4-\(size)-it-Q4_0.gguf"
        return ModelInfo(
            id: "gemma-4-\(size.lowercased())-q4_0", kind: .translation, name: name, summary: summary, strengths: strengths,
            source: .gguf(url: URL(string: "https://huggingface.co/ggml-org/gemma-4-\(size)-it-GGUF/resolve/main/\(file)")!,
                          fileName: file),
            sizeMB: sizeMB, speed: speed, quality: quality, license: "Apache 2.0", commercialUse: true,
            minRAMGB: minRAMGB, englishOnly: false, recommendedRAMGB: recommendedRAMGB, isLLM: true)
    }

    static let translation = madlad + gemma

    static let all = speech + translation

    /// Gemma 4 E2B: more natural than MADLAD in testing (spoken register, consistent names)
    /// and it fits 8 GB, so it's the default and the recommendation on every Mac.
    static let defaultTranslation = gemma[0].id

    static func model(id: String) -> ModelInfo? {
        all.first { $0.id == id }
    }

    /// Apple Speech where available (lowest lag); otherwise WhisperKit's pick for this chip.
    static var recommendedSpeech: String {
        if AppleSpeech.isAvailable { return appleSpeechID }
        return recommendedWhisper
    }

    /// The Whisper model to use when Apple Speech can't (unsupported language, auto-detect):
    /// the fast Turbo, which decoded a line in 0.6 s on an M2 against ~1 s for plain Turbo.
    static var recommendedWhisper: String { fastTurboID }

    /// For movies and subtitle files: Gemma reads the scene.
    static var recommendedTranslation: String { defaultTranslation }

    /// For live Translate, where every half second of lag shows: MADLAD is the quickest.
    static let recommendedLiveTranslation = madlad[0].id
}

enum Hardware {
    static let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}
