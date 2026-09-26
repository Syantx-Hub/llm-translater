import Foundation

struct Language: Identifiable, Hashable {
    /// Whisper / ISO 639-1 code, also what the translation sidecar expects.
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    /// Burmese and the main film languages first, then the rest by name. Codes are Whisper's
    /// (ISO 639-1), which MADLAD-400 uses too. python/translators.py covers a subset for NLLB.
    static let all: [Language] = [
        Language(code: "my", name: "Burmese"),
        Language(code: "en", name: "English"),
        Language(code: "ko", name: "Korean"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "zh", name: "Chinese"),
        // The rest, alphabetically.
        Language(code: "ar", name: "Arabic"),
        Language(code: "bn", name: "Bengali"),
        Language(code: "bg", name: "Bulgarian"),
        Language(code: "ca", name: "Catalan"),
        Language(code: "cs", name: "Czech"),
        Language(code: "da", name: "Danish"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "el", name: "Greek"),
        Language(code: "gu", name: "Gujarati"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "hu", name: "Hungarian"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "it", name: "Italian"),
        Language(code: "kn", name: "Kannada"),
        Language(code: "km", name: "Khmer"),
        Language(code: "lo", name: "Lao"),
        Language(code: "ms", name: "Malay"),
        Language(code: "ml", name: "Malayalam"),
        Language(code: "mr", name: "Marathi"),
        Language(code: "ne", name: "Nepali"),
        Language(code: "fa", name: "Persian"),
        Language(code: "pl", name: "Polish"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "pa", name: "Punjabi"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "ru", name: "Russian"),
        Language(code: "si", name: "Sinhala"),
        Language(code: "es", name: "Spanish"),
        Language(code: "sw", name: "Swahili"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "ta", name: "Tamil"),
        Language(code: "te", name: "Telugu"),
        Language(code: "th", name: "Thai"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "ur", name: "Urdu"),
        Language(code: "vi", name: "Vietnamese"),
    ]

    static let auto = "auto"

    static func isSupported(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }
}
