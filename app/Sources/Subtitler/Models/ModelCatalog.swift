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

    var sizeLabel: String {
        sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB"
    }
}

enum ModelCatalog {
    static let speech: [ModelInfo] = [
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

    /// WhisperKit's pick for this chip, if it is in our list; otherwise Turbo.
    static var recommendedSpeech: String {
        let recommended = Transcriber.recommendedModel
        return speech.contains { $0.id == recommended } ? recommended : speech[0].id
    }

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
