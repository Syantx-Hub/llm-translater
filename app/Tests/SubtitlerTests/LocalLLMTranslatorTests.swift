import Foundation
import Testing
@testable import Subtitler

@Suite struct LocalLLMPromptTests {
    @Test func usesGemma4TurnsWithThinkingOff() {
        let prompt = LocalLLMPrompt.gemma(system: "S", turns: [(user: "U1", model: "M1")], user: "U2")
        #expect(prompt == "<|turn>system\nS<turn|>\n<|turn>user\nU1<turn|>\n<|turn>model\nM1<turn|>\n<|turn>user\nU2<turn|>\n<|turn>model\n")
        #expect(!prompt.contains("<|think|>"))
    }

    @Test func grammarAllowsExactlyTheNumberedLines() {
        let grammar = LocalLLMPrompt.linesGrammar(count: 3)
        #expect(grammar.hasPrefix(#"root ::= "1. " text "\n" "2. " text "\n" "3. " text"#))
        #expect(grammar.contains(#"text ::= [^\n<]{1,400}"#))
        let burmese = LocalLLMPrompt.linesGrammar(count: 1, target: "my")
        #expect(burmese.contains(#"text ::= [ -;=-~\u00A0-\u024F\u2000-\u206F\u266A-\u266B\u1000-\u109F\uAA60-\uAA7F]{1,400}"#))
    }

    @Test func namesGrammarFixesEachNameAndEscapesQuotes() {
        let grammar = LocalLLMPrompt.namesGrammar(["Peter", #"Sam "Red""#])
        #expect(grammar.contains(#""1. Peter → " text"#))
        #expect(grammar.contains(#""2. Sam \"Red\" → " text"#))
    }

    @Test func keepsOnlyNamesWrittenInTheTargetScript() {
        let reply = "1. Peter → ပီတာ\n2. May → May\n3. Queens → ကွင်းစ်"
        let sheet = LocalLLMPrompt.parseNames(reply, names: ["Peter", "May", "Queens"], target: "my")
        #expect(sheet == "Peter → ပီတာ\nQueens → ကွင်းစ်")
    }

    @Test func batchListsOnlyTheNamesInPlayWithEarlierTranslations() {
        let film = FilmContext(names: ["Peter", "May"], cast: "Peter → ပီတာ\nMay → မေ\nFrom the viewer: May is Peter's aunt")
        let prompt = LocalLLMPrompt.batch(["Peter, come here."], context: [("Where is he?", "သူ ဘယ်မှာလဲ။"), ("Hi.", nil)],
                                          film: film, from: "en", to: "my")
        #expect(prompt.contains("Names: Peter → ပီတာ\n"))
        #expect(!prompt.contains("May → မေ"))
        #expect(prompt.contains("From the viewer: May is Peter's aunt"))
        #expect(prompt.contains("> Where is he?\n  = သူ ဘယ်မှာလဲ။\n> Hi.\n"))
        #expect(prompt.contains("Translate these 1 lines:\n1. Peter, come here.<turn|>"))
        // The Burmese worked example comes first, as an earlier turn.
        #expect(prompt.contains("1. ဘယ်သွားမလို့လဲ။"))
    }

    @Test func workedExamplesForMajorTargetsOnly() {
        let french = LocalLLMPrompt.batch(["Hello."], context: [], film: FilmContext(), from: "en", to: "fr")
        #expect(french.contains("into French"))
        #expect(french.contains("Names: Peter\n") && french.contains("1. Tu vas où ?"))
        #expect(LocalLLMPrompt.batch(["Hi."], context: [], film: FilmContext(), from: "en", to: "ko").contains("Names: Peter → 피터"))
        let czech = LocalLLMPrompt.batch(["Hello."], context: [], film: FilmContext(), from: "en", to: "cs")
        #expect(czech.components(separatedBy: "<|turn>user").count == 2)
        // Every example has its three lines, and every script target a spelling of each name.
        #expect(LocalLLMPrompt.examples.values.allSatisfy { $0.count == 3 })
        #expect(LocalLLMPrompt.scriptNames.allSatisfy { $0.value.count == 3 && LocalLLMPrompt.script(of: $0.key) != nil })
        #expect(LocalLLMPrompt.namesPrompt(["Mina"], to: "ja").contains("1. Peter → ピーター"))
    }

    @Test func checksScriptCopiesAndRunaways() {
        #expect(LocalLLMPrompt.acceptable("ဘယ်သွားမလို့လဲ။", source: "Where are you going?", target: "my"))
        #expect(!LocalLLMPrompt.acceptable("Where are you going?", source: "Where are you going?", target: "my"))
        #expect(!LocalLLMPrompt.acceptable("", source: "Hi.", target: "my"))
        #expect(!LocalLLMPrompt.acceptable(String(repeating: "က", count: 200), source: "Hi.", target: "my"))
        #expect(LocalLLMPrompt.acceptable("♪", source: "♪", target: "my"))
        #expect(!LocalLLMPrompt.acceptable("hello", source: "Hello", target: "fr"))
        #expect(LocalLLMPrompt.acceptable("Bonjour", source: "Hello", target: "fr"))
        // A Bengali syllable slipped into a Burmese name.
        #expect(!LocalLLMPrompt.acceptable("ဒ্যামေ့ဂျ် ကွန်ထရိုးလ်", source: "Damage Control", target: "my"))
        #expect(LocalLLMPrompt.acceptable("ဒန်းမေ့ချ် (Damage Control)", source: "Damage Control", target: "my"))
    }

    @Test func splitsGlossaryFromNotes() {
        let (glossary, notes) = LocalLLMPrompt.split("Peter → ပီတာ\n\nThey are friends")
        #expect(glossary.map(\.name) == ["Peter"])
        #expect(glossary.map(\.written) == ["ပီတာ"])
        #expect(notes == "They are friends")
    }

    @Test func commonPrefixOfTokens() {
        #expect(LocalLLMPrompt.commonPrefix([1, 2, 3, 4], [1, 2, 9]) == 2)
        #expect(LocalLLMPrompt.commonPrefix([], [1]) == 0)
    }
}

@Suite struct ModelFitTests {
    private let gemma31 = ModelCatalog.gemma.first { $0.id == "gemma-4-31b-q4_0" }!
    private let e4b = ModelCatalog.gemma.first { $0.id == "gemma-4-e4b-q4_0" }!

    @Test func fitDependsOnMinimumAndRecommendedMemory() {
        #expect(e4b.fit(ramGB: 8) == .tight)
        #expect(e4b.fit(ramGB: 16) == .comfortable)
        #expect(gemma31.fit(ramGB: 16) == .tooBig)
        #expect(gemma31.fit(ramGB: 64) == .comfortable)
    }

    @Test func fitRowSaysWhatItNeeds() {
        #expect(MemoryFit(model: e4b, ramGB: 8).requirement == "needs 8 GB, 16 GB recommended")
        #expect(MemoryFit(model: e4b, ramGB: 8).verdict.hasPrefix("May run on this Mac (8 GB)"))
        #expect(MemoryFit(model: gemma31, ramGB: 8).verdict == "Too big for this Mac (8 GB)")
        #expect(MemoryFit(model: ModelCatalog.madlad[0], ramGB: 8).requirement == "needs 8 GB")
    }

    @Test func gemmaModelsAreLLMsWithDistinctFiles() {
        #expect(ModelCatalog.gemma.count == 5)
        #expect(ModelCatalog.gemma.allSatisfy { $0.isLLM && $0.kind == .translation && $0.commercialUse })
        #expect(!ModelCatalog.madlad.contains { $0.isLLM })
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ModelCatalog.defaultTranslation == "gemma-4-e2b-q4_0")
        #expect(ModelCatalog.recommendedTranslation == ModelCatalog.defaultTranslation)
        #expect(ModelCatalog.recommendedLiveTranslation == ModelCatalog.madlad[0].id)
        guard case .gguf(let url, let file) = ModelCatalog.gemma[0].source else { Issue.record("not a GGUF"); return }
        #expect(url.absoluteString == "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf")
        #expect(file == "gemma-4-E2B-it-Q4_0.gguf")
    }
}
