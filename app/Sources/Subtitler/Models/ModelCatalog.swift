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

    var isBuiltIn: Bool { source == .system }

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

    static let translation: [ModelInfo] = [
        ModelInfo(
            id: "madlad400-3b-q4_k_m", kind: .translation,
            name: "MADLAD-400 3B",
            summary: "Google's translation model for 400+ languages, including Burmese.",
            strengths: ["Runs fully offline on the GPU", "Free for commercial use (Apache 2.0)"],
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

    static let all = speech + translation

    static let defaultTranslation = translation[0].id

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

    static var recommendedTranslation: String {
        Hardware.ramGB >= 16 ? translation[1].id : translation[0].id
    }
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
