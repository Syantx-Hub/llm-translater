import Foundation
import Testing
@testable import Subtitler

/// Canned Wikipedia and TMDB replies, routed by URL; records every request.
private final class FakeWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { sent } }

    var pages = #"{"query":{"pages":[{"title":"Parasite (2019 film)","missing":true},{"title":"Parasite (film)","pageid":2}],"redirects":[]}}"#
    var extract = #"{"query":{"pages":[{"title":"Parasite (film)","extract":"Parasite is a 2019 South Korean black comedy thriller film directed by Bong Joon Ho. It stars Song Kang-ho, Lee Sun-kyun and Cho Yeo-jeong. The film follows a poor family.\nSecond paragraph."}]}}"#
    let sections = #"{"parse":{"sections":[{"index":"1","line":"Plot"},{"index":"2","line":"Cast"},{"index":"3","line":"Production"}]}}"#
    let plot = #"{"parse":{"wikitext":"== Plot ==\n* Ki-woo as the tutor: SPOILER the family is revealed."}}"#
    let cast = #"""
    {"parse":{"wikitext":"== Cast ==\n<!-- order per credits -->\n* [[Song Kang-ho]] as Kim Ki-taek, the patriarch of the Kim family.<ref name=\"a\">x</ref> Later he does something.\n* [[Choi Woo-shik]] as [[Kim Ki-woo]]:<br />Ki-taek's son, who becomes a tutor. More story here.\n** Nested detail line\n* [[Park So-dam]] as Kim Ki-jung {{efn|Also called Jessica}}, Ki-taek's daughter."}}
    """#
    let langlinks = #"{"query":{"pages":[{"title":"Kim Ki-woo","langlinks":[{"lang":"ko","title":"김기우 (기생충)"}]},{"title":"Kim Ki-taek","redirect":true,"langlinks":[{"lang":"ko","title":"기생충"}]}]}}"#
    let search = #"{"query":{"search":[{"title":"Spider-Man: Brand New Day"}]}}"#
    var tmdbSearch = #"{"results":[{"id":496243,"title":"Parasite","release_date":"2019-05-30"},{"id":1,"title":"Parasite","release_date":"1982-03-12"}]}"#
    let tmdbCredits = #"{"cast":[{"name":"Song Kang-ho","character":"Kim Ki-taek","order":0},{"name":"Lee Jung-eun","character":"Moon-gwang","order":5}]}"#

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let body: String
        if url.host == "api.themoviedb.org" {
            body = url.path.contains("search") ? tmdbSearch : tmdbCredits
        } else if value("list") == "search" {
            body = search
        } else if value("action") == "parse" {
            body = value("prop") == "sections" ? sections : value("section") == "2" ? cast : plot
        } else if value("prop") == "extracts" {
            body = extract
        } else if value("prop") == "langlinks" {
            body = langlinks
        } else {
            body = pages
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct FilmBackgroundTests {
    private func lookup(_ web: FakeWeb, enabled: Bool = true, secrets: SecretStore = MemorySecretStore()) -> FilmBackgroundLookup {
        FilmBackgroundLookup(settings: { enabled }, cache: FilmBackgroundCache(folder: try! makeTemporaryDirectory()),
                             secrets: secrets, send: { try await web.send($0) })
    }

    @Test func titleToQuery() throws {
        let film = try #require(FilmQuery("Parasite (2019)"))
        #expect(film == FilmQuery(title: "Parasite", year: 2019))
        #expect(film.wikipediaCandidates == ["Parasite (2019 film)", "Parasite (film)", "Parasite"])
        #expect(FilmQuery("Squid Game 2021") == FilmQuery(title: "Squid Game", year: 2021))
        let episode = try #require(FilmQuery("Breaking Bad S01E01"))
        #expect(episode == FilmQuery(title: "Breaking Bad", season: 1, episode: 1))
        #expect(episode.wikipediaCandidates == ["Breaking Bad (TV series)", "Breaking Bad"])
        #expect(FilmQuery(nil) == nil && FilmQuery("x") == nil)
        let url = Wikipedia.url(["action": "query", "titles": "Parasite (film)"]).absoluteString
        #expect(url.hasPrefix("https://en.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&titles=Parasite%20(film)"))
    }

    @Test func readsOnlyTheLeadAndTheCastSectionNeverThePlot() async throws {
        let web = FakeWeb()
        let background = try #require(await lookup(web).lookup(FilmQuery("Parasite (2019)"), target: "ko"))
        #expect(background.source == "Wikipedia" && background.page == "Parasite (film)")
        #expect(background.summary == "Parasite is a 2019 South Korean black comedy thriller film directed by Bong Joon Ho. It stars Song Kang-ho, Lee Sun-kyun and Cho Yeo-jeong.")
        #expect(background.characters == [
            .init(name: "Kim Ki-taek", actor: "Song Kang-ho", role: "the patriarch of the Kim family."),
            .init(name: "Kim Ki-woo", actor: "Choi Woo-shik", role: "Ki-taek's son, who becomes a tutor."),
            .init(name: "Kim Ki-jung", actor: "Park So-dam", role: "Ki-taek's daughter."),
        ])
        // Spellings from Korean Wikipedia, qualifier dropped; the redirect is skipped.
        #expect(background.spellings == ["Kim Ki-woo": "김기우"])
        let sections = web.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "section" }?.value }
        #expect(sections == ["2"])
        #expect(!background.text(target: "ko").contains("SPOILER"))
        #expect(web.requests.allSatisfy { $0.url?.scheme == "https" })
    }

    @Test func cacheHitSendsNothing() async throws {
        let web = FakeWeb()
        let lookup = lookup(web)
        let first = await lookup.lookup(FilmQuery("Parasite (2019)"), target: "ko")
        let count = web.requests.count
        #expect(await lookup.lookup(FilmQuery("Parasite (2019)"), target: "ko") == first)
        #expect(web.requests.count == count)
    }

    @Test func nothingFoundIsCachedToo() async throws {
        let web = FakeWeb()
        web.pages = #"{"query":{"pages":[{"title":"Parasite","pageid":3,"pageprops":{"disambiguation":""}}]}}"#
        let lookup = lookup(web)
        #expect(await lookup.lookup(FilmQuery("Parasite"), target: "my") == nil)
        let count = web.requests.count
        #expect(await lookup.lookup(FilmQuery("Parasite"), target: "my") == nil)
        #expect(web.requests.count == count)
    }

    @Test func toggleOffSendsNothing() async throws {
        let web = FakeWeb()
        #expect(await lookup(web, enabled: false).lookup(FilmQuery("Parasite (2019)"), target: "my") == nil)
        #expect(web.requests.isEmpty)
    }

    @Test func tmdbIsSkippedWithoutAKey() async throws {
        let web = FakeWeb()
        _ = await lookup(web).lookup(FilmQuery("Parasite (2019)"), target: "my")
        #expect(!web.requests.contains { $0.url?.host == "api.themoviedb.org" })
    }

    @Test func tmdbWithAKeyAddsMissingCharactersAndKeepsTheKeyOutOfTheURL() async throws {
        let web = FakeWeb()
        let secrets = MemorySecretStore()
        try secrets.save("token-123", for: TMDB.secretName)
        let background = try #require(await lookup(web, secrets: secrets).lookup(FilmQuery("Parasite (2019)"), target: "my"))
        #expect(background.source == "Wikipedia + TMDB")
        #expect(background.characters.last == .init(name: "Moon-gwang", actor: "Lee Jung-eun", role: ""))
        #expect(background.characters.filter { $0.name == "Kim Ki-taek" }.count == 1)
        let tmdb = web.requests.filter { $0.url?.host == "api.themoviedb.org" }
        #expect(tmdb.map(\.url!.path) == ["/3/search/movie", "/3/movie/496243/credits"])
        #expect(tmdb.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token-123" })
        #expect(!tmdb.contains { $0.url!.absoluteString.contains("token-123") })
    }

    @Test func ambiguousTMDBTitleIsIgnored() throws {
        let results = Data(#"{"results":[{"id":1,"title":"Parasite","release_date":"2019-05-30"},{"id":2,"title":"Parasite","release_date":"1982-03-12"}]}"#.utf8)
        #expect(TMDB.match(results, query: FilmQuery(title: "Parasite")) == nil)
        #expect(TMDB.match(results, query: FilmQuery(title: "Parasite", year: 2019))?.id == 1)
        let episode = Data(#"{"cast":[{"name":"A","character":"Walter White"}],"guest_stars":[{"name":"B","character":"Tuco (voice)"}]}"#.utf8)
        #expect(TMDB.characters(episode).map(\.name) == ["Walter White", "Tuco"])
    }

    @Test func notAFilmPageFallsBackQuietly() async throws {
        let web = FakeWeb()
        web.extract = #"{"query":{"pages":[{"extract":"A parasite is an organism that lives on another."}]}}"#
        #expect(await lookup(web).lookup(FilmQuery("Parasite (2019)"), target: "my") == nil)
    }

    @Test func searchFindsATitleThatLostItsColon() async throws {
        let web = FakeWeb()
        web.pages = #"{"query":{"pages":[{"title":"Spider-Man Brand New Day","missing":true}]}}"#
        web.extract = #"{"query":{"pages":[{"extract":"Spider-Man: Brand New Day is a 2026 American superhero film."}]}}"#
        let background = await lookup(web).lookup(FilmQuery("Spider-Man Brand New Day (2026)"), target: "en")
        #expect(background?.page == "Spider-Man: Brand New Day")
        #expect(Wikipedia.searchMatch(Data(web.search.utf8), query: FilmQuery(title: "Spider-Man Far From Home")) == nil)
    }

    @Test func editableTextReadsBack() {
        let background = FilmBackground(
            source: "Wikipedia", page: "Parasite (film)", summary: "Parasite is a 2019 film.",
            characters: [.init(name: "Kim Ki-taek", actor: "Song Kang-ho", role: "the father."),
                         .init(name: "Moon-gwang", actor: nil, role: "")],
            spellings: ["Kim Ki-woo": "김기우"])
        let text = background.text(target: "ko")
        #expect(text == """
        From Wikipedia: Parasite (film)
        Parasite is a 2019 film.
        - Kim Ki-taek (Song Kang-ho): the father.
        - Moon-gwang
        Names in Korean: Kim Ki-woo → 김기우
        """)
        #expect(FilmBackground.parse(text, target: "ko") == background)
        // Another target's spellings are ignored.
        #expect(FilmBackground.parse(text, target: "ja").spellings.isEmpty)
    }

    @Test func wikitextToPlainText() {
        #expect(Wikipedia.plainText("''[[A (film)|A]]'' {{nowrap|B}}<ref>x</ref> {{cite|{{y}}}} [[C]]<br/>D") == "A B C D")
    }

    @Test func resolveKeepsTheViewersEditsAndNeverLooksUpWhenOff() async throws {
        let defaults = try #require(UserDefaults(suiteName: "FilmBackgroundTests.\(UUID())"))
        let file = URL(fileURLWithPath: "/tmp/Parasite (2019).ko.srt")
        let web = FakeWeb()
        #expect(await FilmBackgroundNotes.resolve(for: file, target: "my", lookup: lookup(web, enabled: false), defaults: defaults) == "")
        #expect(web.requests.isEmpty)
        FilmBackgroundNotes.set("- Ki-woo: the son", for: file, defaults: defaults)
        #expect(await FilmBackgroundNotes.resolve(for: file, target: "my", lookup: lookup(web), defaults: defaults) == "- Ki-woo: the son")
        #expect(web.requests.isEmpty)
    }
}

@Suite struct FilmBackgroundInTranslationTests {
    private let background = """
    From Wikipedia: Parasite (film)
    Parasite is a 2019 film.
    - Kim Ki-taek (Song Kang-ho): the father of the Kim family.
    - Kim Ki-woo (Choi Woo-shik): Ki-taek's son, who becomes a tutor.
    - Park Dong-ik (Lee Sun-kyun): a wealthy CEO.
    Names in Burmese: Kim Ki-woo → ကင်မ်ကီဝူး
    """

    @Test func cloudCastRequestTreatsItAsTrustedFacts() {
        let request = LLMPrompt.castRequest(["Hi."], title: "Parasite (2019)", background: background)
        #expect(request.contains("Background on this film, looked up online. Trust it for who each character is"))
        #expect(request.contains("keep the spoiler-free rules"))
        #expect(request.contains("- Kim Ki-woo (Choi Woo-shik): Ki-taek's son"))
        #expect(!LLMPrompt.castRequest(["Hi."]).contains("Background"))
    }

    @Test func castSheetGetsTheBackground() async throws {
        let translator = FakeBatchTranslator(batchSize: 3)
        let cues = [SubtitleCue(start: 0, end: 1, text: "Hi.")]
        _ = try await SubtitleTranslator.translate(cues, from: "en", to: "my", with: translator,
                                                   background: { "- Kim Ki-woo: the son" }) { _ in }
        #expect(await translator.backgrounds == ["- Kim Ki-woo: the son"])
    }

    @Test func gemmaGlossaryAddsTheCastNamesTheDialogueUses() {
        let facts = FilmBackground.parse(background, target: "my")
        let dialogue = ["Ki-woo, come here.", "Mr. Park is home.", "Kim Ki-woo is my son.", "Kim Ki-woo is late."]
        let names = LocalLLMPrompt.glossaryNames(dialogue: dialogue, background: facts)
        #expect(names.contains("Kim Ki-woo"))
        #expect(!names.contains("Kim Ki-taek")) // never said
        #expect(!names.contains("Park Dong-ik"))
    }

    @Test func gemmaCharacterListIsShortAndOnlyWhoIsMentioned() {
        let facts = FilmBackground.parse(background, target: "my")
        let lines = LocalLLMPrompt.characterLines(facts, dialogue: ["Ki-woo!", "Where's Ki-woo?", "Mr. Park called."])
        #expect(lines == ["- Kim Ki-woo: Ki-taek's son, who becomes a tutor.", "- Park Dong-ik: a wealthy CEO."])
        let film = FilmContext(cast: (["Kim Ki-woo → ကင်မ်ကီဝူး"] + lines).joined(separator: "\n"))
        let prompt = LocalLLMPrompt.batch(["Park is here."], context: [], film: film, from: "en", to: "my")
        #expect(prompt.contains("Who's who (pick pronouns and politeness to fit):\n- Park Dong-ik: a wealthy CEO.\n"))
        #expect(!prompt.contains("- Kim Ki-woo:"))
        #expect(!prompt.contains("ကင်မ်ကီဝူး"))
    }
}
