import Foundation
import llama

enum LocalLLMError: LocalizedError {
    case promptTooLong(Int)
    case badGrammar

    var errorDescription: String? {
        switch self {
        case .promptTooLong(let tokens): "The request (\(tokens) tokens) doesn't fit the model's context."
        case .badGrammar: "The output format could not be set up."
        }
    }
}

/// Runs a Gemma 4 chat GGUF with llama.cpp on the GPU, as a batch translator.
///
/// Built to work well with small models (2–4B), which follow short, concrete prompts but
/// drift on long ones:
/// - A grammar forces the reply into exactly one numbered line per input, so a batch
///   never comes back merged, split or short.
/// - Small batches with a short prompt and a worked example, instead of the cloud
///   prompt's long rules.
/// - Names are transliterated once for the whole film and then given as a fixed list,
///   so "Peter" is written the same way in every batch.
/// - Earlier lines come with the translations already chosen for them, so register and
///   wording carry over between batches.
/// - Each line is checked (target script, not copied, not runaway) and a bad one is
///   translated again on its own.
/// - The fixed start of the prompt stays in the KV cache between requests.
actor LocalLLMTranslator: BatchTranslating {
    /// Small models keep track of about this many lines at once.
    static let defaultBatchSize = 8
    nonisolated let batchSize = LocalLLMTranslator.defaultBatchSize

    private let modelPath: String
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    /// What the KV cache holds, so a request only decodes what differs from the last.
    private var cached: [llama_token] = []
    /// Recent source → translation, shown with the context lines of later requests.
    private var recent: [String: String] = [:]
    private var recentOrder: [String] = []

    private let contextSize: Int32 = 4096
    private let chunk: Int32 = 512

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func start() async throws {
        guard model == nil else { return }
        Llama.initBackend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.loadFailed(modelPath)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(chunk)
        contextParams.n_ubatch = UInt32(chunk)
        // Gemma's sliding-window layers otherwise drop the old positions the prompt cache reuses.
        contextParams.swa_full = true
        contextParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.loadFailed(modelPath)
        }
        self.model = model
        self.context = context
        // The first decode compiles Metal kernels; do it now, not on the first line.
        _ = try? await translate("Hello.", from: "en", to: "my", context: [])
    }

    func stop() async {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        cached = []
    }

    /// One line (live Translate). Remembered like a batch, so the next line sees the
    /// translation this one got, and the wording and pronouns carry on.
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        let translation = try translateLines([text], from: source, to: target, context: context, film: FilmContext())[0]
        remember(zip([text], [translation]))
        return translation
    }

    func translateBatch(_ lines: [String], from source: String, to target: String,
                        context: [String], film: FilmContext) async throws -> [String] {
        var result = try translateLines(lines, from: source, to: target, context: context, film: film)
        guard lines.count > 1 else { return result }
        // A line that fails the checks gets a second try on its own, with the lines before it.
        for index in result.indices where !LocalLLMPrompt.acceptable(result[index], source: lines[index], target: target) {
            Trace.log("local-llm: retrying line \(index + 1) of \(lines.count)")
            let before = context + lines[..<index]
            let retry = try translateLines([lines[index]], from: source, to: target,
                                           context: Array(before.suffix(SentenceTranslation.contextLines)), film: film)[0]
            if LocalLLMPrompt.acceptable(retry, source: lines[index], target: target) { result[index] = retry }
        }
        remember(zip(lines, result))
        return result
    }

    /// No reasoning about the film is asked of a small model. The sheet is:
    /// - the film's names as "Peter → ပီတာ" lines (targets in another script only):
    ///   spellings from the background's Wikipedia when it has them, the rest
    ///   transliterated once here, so every batch writes them the same way;
    /// - up to ten "- Name: who they are" lines from the background, for pronouns and
    ///   politeness; each batch shows only the characters it mentions.
    func castSheet(dialogue: [String], title: String?, background: String,
                   from source: String, to target: String) async throws -> String {
        let facts = FilmBackground.parse(background, target: target)
        let names = LocalLLMPrompt.glossaryNames(dialogue: dialogue, background: facts)
        var glossary: [String] = []
        if LocalLLMPrompt.script(of: target) != nil, !names.isEmpty {
            let known = names.filter { facts.spellings[$0] != nil }
            glossary = known.map { "\($0) → \(facts.spellings[$0]!)" }
            let unknown = names.filter { facts.spellings[$0] == nil }
            if !unknown.isEmpty {
                let reply = try generate(LocalLLMPrompt.namesPrompt(unknown, to: target),
                                         grammar: LocalLLMPrompt.namesGrammar(unknown, target: target),
                                         maxTokens: unknown.count * 24 + 16)
                let sheet = LocalLLMPrompt.parseNames(reply, names: unknown, target: target)
                if !sheet.isEmpty { glossary.append(sheet) }
            }
        }
        let people = LocalLLMPrompt.characterLines(facts, dialogue: dialogue)
        let sheet = (glossary + people).joined(separator: "\n")
        Trace.log("local-llm: cast sheet\n\(sheet)")
        return sheet
    }

    private func translateLines(_ lines: [String], from source: String, to target: String,
                                context: [String], film: FilmContext) throws -> [String] {
        let shown = context.map { ($0, recent[$0]) }
        let prompt = LocalLLMPrompt.batch(lines, context: shown, film: film, from: source, to: target)
        let started = Date()
        let reply = try generate(prompt, grammar: LocalLLMPrompt.linesGrammar(count: lines.count, target: target),
                                 maxTokens: lines.reduce(0) { $0 + $1.utf8.count * 3 + 24 } + 16)
        Trace.log("local-llm: \(lines.count) lines in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        if let parsed = LLMPrompt.parseNumbered(reply, count: lines.count) { return parsed }
        // Only a reply cut short by the token limit gets here; halve and try again.
        guard lines.count > 1 else { return [LLMPrompt.cleanSingle(reply)] }
        Trace.log("local-llm: \(lines.count)-line reply didn't line up; splitting")
        let half = lines.count / 2
        let first = try translateLines(Array(lines[..<half]), from: source, to: target, context: context, film: film)
        let second = try translateLines(Array(lines[half...]), from: source, to: target,
                                        context: context + lines[..<half], film: film)
        return first + second
    }

    private func remember(_ pairs: Zip2Sequence<[String], [String]>) {
        for (line, translation) in pairs where recent[line] == nil {
            recent[line] = translation
            recentOrder.append(line)
        }
        if recentOrder.count > 200 {
            for line in recentOrder.prefix(recentOrder.count - 200) { recent[line] = nil }
            recentOrder.removeFirst(recentOrder.count - 200)
        }
    }

    /// Greedy decoding under a GBNF grammar. Reuses the KV cache for the prompt's shared start.
    private func generate(_ prompt: String, grammar: String, maxTokens: Int) throws -> String {
        guard let model, let context else { throw LlamaError.loadFailed(modelPath) }
        let vocab = llama_model_get_vocab(model)
        let input = Llama.tokenize(prompt, vocab: vocab)
        let room = Int(contextSize) - input.count
        guard room > 32 else { throw LocalLLMError.promptTooLong(input.count) }

        guard let constraint = llama_sampler_init_grammar(vocab, grammar, "root") else { throw LocalLLMError.badGrammar }
        defer { llama_sampler_free(constraint) }

        // Keep the common prefix; the last prompt token is always decoded again for its logits.
        let memory = llama_get_memory(context)
        var keep = min(LocalLLMPrompt.commonPrefix(cached, input), input.count - 1)
        if !llama_memory_seq_rm(memory, 0, llama_pos(keep), -1) {
            llama_memory_clear(memory, true)
            keep = 0
        }
        cached = Array(input.prefix(keep))
        var start = keep
        while start < input.count {
            var part = Array(input[start..<min(start + Int(chunk), input.count)])
            let decoded = part.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
            }
            guard decoded == 0 else { cached = []; throw LlamaError.decodeFailed(decoded) }
            cached += part
            start += part.count
            try Task.checkCancellation()
        }

        var output: [llama_token] = []
        for _ in 0..<min(maxTokens, room) {
            var token = sampleGreedy(context, constraint: constraint, vocabSize: Int(llama_vocab_n_tokens(vocab)))
            if llama_vocab_is_eog(vocab, token) { break }
            output.append(token)
            if LlamaTranslator.isLooping(output, window: 16) { output.removeLast(16); break }
            let decoded = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard decoded == 0 else { cached = []; throw LlamaError.decodeFailed(decoded) }
            cached.append(token)
            try Task.checkCancellation()
        }
        return Llama.detokenize(output, vocab: vocab)
    }

    /// The most likely token the grammar allows. Checking only the top token first, and the
    /// whole vocabulary just when the grammar rejects it, is what keeps a grammar cheap:
    /// filtering Gemma's 262k tokens at every step made a batch half again as slow.
    private func sampleGreedy(_ context: OpaquePointer, constraint: UnsafeMutablePointer<llama_sampler>,
                              vocabSize: Int) -> llama_token {
        let logits = llama_get_logits_ith(context, -1)!
        var best = 0
        for index in 1..<vocabSize where logits[index] > logits[best] { best = index }
        var top = llama_token_data(id: llama_token(best), logit: logits[best], p: 0)
        let allowed = withUnsafeMutablePointer(to: &top) { pointer in
            var candidates = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(constraint, &candidates)
            return pointer.pointee.logit.isFinite
        }
        var token = llama_token(best)
        if !allowed {
            var all = (0..<vocabSize).map { llama_token_data(id: llama_token($0), logit: logits[$0], p: 0) }
            all.withUnsafeMutableBufferPointer { buffer in
                var candidates = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
                llama_sampler_apply(constraint, &candidates)
            }
            token = all.max { $0.logit < $1.logit }!.id
        }
        llama_sampler_accept(constraint, token)
        return token
    }
}

/// The prompts, grammars and checks behind `LocalLLMTranslator`. Pure, so tests can see
/// exactly what a small model is given.
enum LocalLLMPrompt {
    // MARK: Chat format

    /// Gemma 4's turns, thinking off. The tokenizer adds `<bos>`.
    static func gemma(system: String, turns: [(user: String, model: String)], user: String) -> String {
        var text = "<|turn>system\n\(system)<turn|>\n"
        for turn in turns {
            text += "<|turn>user\n\(turn.user)<turn|>\n<|turn>model\n\(turn.model)<turn|>\n"
        }
        return text + "<|turn>user\n\(user)<turn|>\n<|turn>model\n"
    }

    // MARK: Translation

    /// Four rules rather than the cloud prompt's eight: small models follow a few well.
    static func system(from source: String, to target: String) -> String {
        let from = source.isEmpty || source == Languages.auto ? "the original language" : Languages.name(source)
        let to = Languages.name(target)
        var rules = """
        You translate film subtitles from \(from) into \(to).
        - Natural spoken \(to), the way people really talk.
        - Names stay names: write them as listed, in \(to) script.
        - One translation for each numbered line. Output only the translations.
        """
        if let note = LLMPrompt.registerNote[target] { rules += "\n- \(note)" }
        return rules
    }

    /// A worked example in the exact request format, where one exists for the target. The
    /// grammar already fixes the format; the example shows the register a subtitle wants.
    static func example(to target: String) -> (user: String, model: String)? {
        guard let lines = examples[target] else { return nil }
        let names = scriptNames[target].map { "Names: Peter → \($0[0])" } ?? "Names: Peter"
        return (
            user: """
            \(names)

            Translate these 3 lines:
            1. Where are you going?
            2. Peter, wait!
            3. I told you, I'm fine.
            """,
            model: lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
    }

    /// The example's three lines, as a subtitler would write them.
    static let examples: [String: [String]] = [
        "my": ["ဘယ်သွားမလို့လဲ။", "ပီတာ၊ ခဏနေဦး။", "ပြောသားပဲ၊ ငါ အဆင်ပြေပါတယ်။"],
        "ko": ["어디 가?", "피터, 잠깐만!", "말했잖아, 난 괜찮아."],
        "ja": ["どこ行くの？", "ピーター、待って！", "言ったでしょ、大丈夫だって。"],
        "zh": ["你要去哪儿？", "彼得，等等！", "我跟你说了，我没事。"],
        "th": ["จะไปไหน", "ปีเตอร์ รอก่อน!", "บอกแล้วไง ฉันไม่เป็นไร"],
        "vi": ["Cậu đi đâu đấy?", "Peter, đợi đã!", "Tớ nói rồi mà, tớ ổn."],
        "id": ["Mau ke mana?", "Peter, tunggu!", "Sudah kubilang, aku baik-baik saja."],
        "es": ["¿Adónde vas?", "¡Peter, espera!", "Ya te lo dije, estoy bien."],
        "fr": ["Tu vas où ?", "Peter, attends !", "Je te l'ai dit, ça va."],
        "de": ["Wo willst du hin?", "Peter, warte!", "Hab ich doch gesagt, mir geht's gut."],
        "pt": ["Aonde você vai?", "Peter, espera!", "Eu te disse, eu tô bem."],
        "it": ["Dove vai?", "Peter, aspetta!", "Te l'ho detto, sto bene."],
        "ru": ["Ты куда?", "Питер, подожди!", "Я же сказал, я в порядке."],
        "hi": ["कहाँ जा रहे हो?", "पीटर, रुको!", "बताया तो था, मैं ठीक हूँ।"],
    ]

    /// "Peter", "London", "Sarah" in targets with their own script, for the examples.
    static let scriptNames: [String: [String]] = [
        "my": ["ပီတာ", "လန်ဒန်", "ဆာရာ"],
        "ko": ["피터", "런던", "사라"],
        "ja": ["ピーター", "ロンドン", "サラ"],
        "zh": ["彼得", "伦敦", "萨拉"],
        "th": ["ปีเตอร์", "ลอนดอน", "ซาราห์"],
        "ru": ["Питер", "Лондон", "Сара"],
        "hi": ["पीटर", "लंदन", "सारा"],
    ]

    /// - Parameter context: earlier lines, each with the translation already given, if any.
    static func batch(_ lines: [String], context: [(String, String?)], film: FilmContext,
                      from source: String, to target: String) -> String {
        let text = (context.map(\.0) + lines).joined(separator: "\n")
        var message = ""
        let (glossary, notes) = split(film.cast)
        let names = glossary.filter { mentions(text, $0.name) }
        // Character lines ("- Name: role") only for the characters this stretch mentions.
        let shownNotes = notes.components(separatedBy: "\n").filter { line in
            guard line.hasPrefix("- ") else { return true }
            let name = line.dropFirst(2).components(separatedBy: ":")[0]
            return FilmBackground.nameParts(name).contains { part in
                mentions(text, part) || part.split(separator: " ").contains { $0.count >= 3 && mentions(text, String($0)) }
            }
        }.joined(separator: "\n")
        if !names.isEmpty {
            message += "Names: " + names.map { "\($0.name) → \($0.written)" }.joined(separator: ", ") + "\n\n"
        } else {
            let plain = film.names.filter { mentions(text, $0) }
            if !plain.isEmpty { message += "Names: \(plain.joined(separator: ", "))\n\n" }
        }
        if !shownNotes.isEmpty {
            message += "Who's who (pick pronouns and politeness to fit):\n\(shownNotes.prefix(700))\n\n"
        }
        if !context.isEmpty {
            message += "Earlier lines, for context only:\n"
            message += context.map { line, translation in
                translation.map { "> \(line)\n  = \($0)" } ?? "> \(line)"
            }.joined(separator: "\n") + "\n\n"
        }
        message += "Translate these \(lines.count) lines:\n"
        message += lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let turns = example(to: target).map { [$0] } ?? []
        return gemma(system: system(from: source, to: target), turns: turns, user: message)
    }

    /// Exactly `count` lines, "1. …" to "count. …", each non-empty and without markup.
    /// For a target with its own script, only that script, Latin and punctuation can be
    /// written, so no stray Bengali or Thai syllable gets in.
    static func linesGrammar(count: Int, target: String = "") -> String {
        let rules = (1...count).map { "\"\($0). \" text" }.joined(separator: " \"\\n\" ")
        return "root ::= \(rules)\ntext ::= \(characters(for: target)){1,400}\n"
    }

    /// A GBNF character class for one line of the target language.
    static func characters(for target: String) -> String {
        guard let ranges = script(of: target) else { return "[^\\n<]" }
        // Printable ASCII without "<", Latin letters, punctuation (quotes, dashes, "…"), "♪".
        let common = [" -;", "=-~", "\\u00A0-\\u024F", "\\u2000-\\u206F", "\\u266A-\\u266B"]
        let own = ranges.map { String(format: "\\u%04X-\\u%04X", $0.lowerBound, $0.upperBound) }
        return "[" + (common + own).joined() + "]"
    }

    // MARK: Names

    static func namesPrompt(_ names: [String], to target: String) -> String {
        let to = Languages.name(target)
        let system = "You write names from films in \(to) script, the way \(to) speakers say them. Sound them out; never translate their meaning."
        var turns: [(user: String, model: String)] = []
        if let written = scriptNames[target] {
            let model = zip(["Peter", "London", "Sarah"], written).enumerated()
                .map { "\($0.offset + 1). \($0.element.0) → \($0.element.1)" }.joined(separator: "\n")
            turns.append((user: "Write these 3 names in \(to) script:\n1. Peter\n2. London\n3. Sarah", model: model))
        }
        let user = "Write these \(names.count) names in \(to) script:\n"
            + names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return gemma(system: system, turns: turns, user: user)
    }

    /// Each line starts with its number and the name, so only the spelling is generated.
    static func namesGrammar(_ names: [String], target: String = "") -> String {
        let rules = names.enumerated().map { "\"\($0.offset + 1). \(escape($0.element)) → \" text" }
            .joined(separator: " \"\\n\" ")
        return "root ::= \(rules)\ntext ::= \(characters(for: target)){1,60}\n"
    }

    /// "Peter → ပီတာ" lines, keeping only spellings in the target's script.
    static func parseNames(_ reply: String, names: [String], target: String) -> String {
        guard let parsed = LLMPrompt.parseNumbered(reply, count: names.count) else { return "" }
        return zip(names, parsed).compactMap { name, line -> String? in
            guard let written = line.components(separatedBy: "→").last?.trimmingCharacters(in: .whitespaces),
                  !written.isEmpty, hasScript(written, of: target), !hasForeignScript(written, target: target) else { return nil }
            return "\(name) → \(written)"
        }.joined(separator: "\n")
    }

    /// Names to keep consistent: the dialogue's own recurring names, plus the background's
    /// character names (whole, or a first or last name) that the dialogue uses.
    static func glossaryNames(dialogue: [String], background: FilmBackground, limit: Int = 40) -> [String] {
        var names = NameGlossary.names(in: dialogue, limit: 30)
        let text = dialogue.joined(separator: "\n")
        for character in background.characters {
            for part in FilmBackground.nameParts(character.name) {
                let words = part.split(separator: " ").map(String.init).filter { $0.count >= 3 && $0.first?.isUppercase == true }
                for name in [part] + (words.count > 1 ? words : []) where !names.contains(name) && usesWord(text, name) {
                    names.append(name)
                }
            }
        }
        return Array(names.prefix(limit))
    }

    /// Up to `limit` "- Name: role" lines for the characters the dialogue mentions most.
    static func characterLines(_ background: FilmBackground, dialogue: [String], limit: Int = 10) -> [String] {
        let text = dialogue.joined(separator: "\n")
        let counted = background.characters.compactMap { character -> (line: String, count: Int)? in
            guard !character.role.isEmpty else { return nil }
            let words = FilmBackground.nameParts(character.name).flatMap { [$0] + $0.split(separator: " ").map(String.init) }
                .filter { $0.count >= 3 }
            let count = words.map { occurrences(text, $0) }.max() ?? 0
            guard count > 0 else { return nil }
            return ("- \(character.name): \(character.role.prefix(110))", count)
        }
        return counted.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(limit).map(\.element.line)
    }

    /// The cast text split into "Name → spelling" entries and everything else (the viewer's notes).
    static func split(_ cast: String) -> (glossary: [(name: String, written: String)], notes: String) {
        var glossary: [(String, String)] = [], notes: [String] = []
        for line in cast.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: " → ")
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                glossary.append((parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                notes.append(line)
            }
        }
        return (glossary, notes.joined(separator: "\n"))
    }

    // MARK: Checks

    /// Unicode ranges of targets written in their own script.
    static func script(of target: String) -> [ClosedRange<UInt32>]? {
        switch target {
        case "my": [0x1000...0x109F, 0xAA60...0xAA7F]
        case "th": [0x0E00...0x0E7F]
        case "lo": [0x0E80...0x0EFF]
        case "km": [0x1780...0x17FF]
        case "ko": [0xAC00...0xD7AF, 0x1100...0x11FF]
        case "ja": [0x3040...0x30FF, 0x4E00...0x9FFF]
        case "zh": [0x4E00...0x9FFF]
        case "ru", "bg", "uk": [0x0400...0x04FF]
        case "el": [0x0370...0x03FF]
        case "ar", "fa", "ur": [0x0600...0x06FF]
        case "hi", "mr", "ne": [0x0900...0x097F]
        case "bn": [0x0980...0x09FF]
        case "si": [0x0D80...0x0DFF]
        default: nil
        }
    }

    static func hasScript(_ text: String, of target: String) -> Bool {
        guard let ranges = script(of: target) else { return true }
        return text.unicodeScalars.contains { scalar in ranges.contains { $0.contains(scalar.value) } }
    }

    /// Letters from a third script, neither the target's nor Latin: small models sometimes
    /// slip a Bengali or Thai syllable into a Burmese name.
    static func hasForeignScript(_ text: String, target: String) -> Bool {
        guard let ranges = script(of: target) else { return false }
        return text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic && scalar.value > 0x024F && !ranges.contains { $0.contains(scalar.value) }
        }
    }

    /// A usable translation: in the target's script when it has one (and no other), not the
    /// source copied back, and not a runaway. Lines without words ("♪", "...") pass as they are.
    static func acceptable(_ translation: String, source: String, target: String) -> Bool {
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.contains(where: \.isLetter) else { return true }
        guard !text.isEmpty, text.count <= source.count * 6 + 20 else { return false }
        if script(of: target) != nil { return hasScript(text, of: target) && !hasForeignScript(text, target: target) }
        return text.caseInsensitiveCompare(source.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
    }

    // MARK: Helpers

    static func commonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private static func mentions(_ text: String, _ name: String) -> Bool {
        text.range(of: name, options: [.caseInsensitive]) != nil
    }

    /// `word` as a whole, capitalised word ("Frank", not "frankly").
    private static func usesWord(_ text: String, _ word: String) -> Bool {
        occurrences(text, word) > 0
    }

    private static func occurrences(_ text: String, _ word: String) -> Int {
        let pattern = "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// A GBNF string literal's contents.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
