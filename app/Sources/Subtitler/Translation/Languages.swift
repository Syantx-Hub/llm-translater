import Foundation

struct Language: Identifiable, Hashable {
    /// Whisper / ISO 639-1 code, also what the translation sidecar expects.
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    /// Keep in sync with LANGS in python/translators.py.
    static let all: [Language] = [
        Language(code: "my", name: "Burmese"),
        Language(code: "en", name: "English"),
        Language(code: "ko", name: "Korean"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "th", name: "Thai"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "ms", name: "Malay"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "fr", name: "French"),
        Language(code: "es", name: "Spanish"),
        Language(code: "de", name: "German"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "ru", name: "Russian"),
        Language(code: "ar", name: "Arabic"),
    ]

    static let auto = "auto"

    static func isSupported(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }
}
