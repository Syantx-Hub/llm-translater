import Foundation
import Testing
@testable import Subtitler

@Suite struct SubtitleSyncTests {
    private let cues = [
        SubtitleCue(start: 60, end: 62, text: "Where have you been all night?"),
        SubtitleCue(start: 63, end: 66, text: "I was waiting for you\nat the station for two hours."),
        SubtitleCue(start: 67, end: 69, text: "<i>Nobody answered the phone.</i>"),
        SubtitleCue(start: 300, end: 303, text: "Don't worry, my brother will drive us home."),
        SubtitleCue(start: 304, end: 306, text: "We have to leave before the rain starts."),
    ]
    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    /// When the video is at `videoTime`, the wall clock reads this.
    private func wall(_ videoTime: TimeInterval, anchor: Date) -> Date { anchor.addingTimeInterval(videoTime) }

    @Test func oneLongClearLineSyncs() throws {
        let sync = SubtitleSync(cues: cues)
        #expect(sync.status(at: t0) == .searching)
        sync.observe("I was waiting for you at the station for two hours", speechEndedAt: wall(66, anchor: t0))
        let time = try #require(sync.videoTime(at: wall(70, anchor: t0)))
        #expect(abs(time - 70) < 0.01)
    }

    @Test func weakMatchesNeedASecondOpinion() {
        let sync = SubtitleSync(cues: cues)
        // Partly misheard: close enough to match, not enough to trust alone.
        sync.observe("I was waiting at the station", speechEndedAt: wall(66, anchor: t0))
        #expect(!sync.isSynced)
        // A second, agreeing line confirms the position.
        sync.observe("Nobody answered phone", speechEndedAt: wall(69, anchor: t0))
        #expect(sync.isSynced)
    }

    @Test func disagreeingWeakMatchesDontSync() {
        let sync = SubtitleSync(cues: cues)
        sync.observe("I was waiting at the station", speechEndedAt: wall(66, anchor: t0))
        sync.observe("Nobody answered phone", speechEndedAt: wall(69, anchor: t0.addingTimeInterval(40)))
        #expect(!sync.isSynced)
    }

    @Test func unrelatedSpeechNeverSyncs() {
        let sync = SubtitleSync(cues: cues)
        sync.observe("The quarterly revenue grew by twelve percent", speechEndedAt: t0)
        sync.observe("Please remember to subscribe to the channel", speechEndedAt: t0.addingTimeInterval(5))
        #expect(!sync.isSynced)
    }

    @Test func showsTheFilesLinesOnTheirOwnTime() {
        let sync = SubtitleSync(cues: cues)
        sync.observe("I was waiting for you at the station for two hours", speechEndedAt: wall(66, anchor: t0))
        // The next line shows at its start — before anyone says it.
        #expect(sync.activeCues(at: wall(67.0, anchor: t0)) == [2])
        #expect(sync.activeCues(at: wall(69.5, anchor: t0)).isEmpty)
        #expect(sync.upcomingCues(at: wall(64, anchor: t0), count: 2) == [1, 2])
    }

    @Test func aSeekMovesTheClockAfterTwoAgreeingLines() throws {
        let sync = SubtitleSync(cues: cues)
        sync.observe("I was waiting for you at the station for two hours", speechEndedAt: wall(66, anchor: t0))
        // The viewer skips ahead: now line 4 is heard although the clock says ~70 s.
        let jumped = t0.addingTimeInterval(-230) // new anchor
        sync.observe("Don't worry, my brother will drive us home", speechEndedAt: wall(303, anchor: jumped))
        #expect(abs(try #require(sync.videoTime(at: wall(303, anchor: jumped))) - 303) > 100) // one line isn't enough
        sync.observe("We have to leave before the rain starts", speechEndedAt: wall(306, anchor: jumped))
        #expect(abs(try #require(sync.videoTime(at: wall(306, anchor: jumped))) - 306) < 0.01)
    }

    @Test func pausingFreezesTheClock() throws {
        let sync = SubtitleSync(cues: cues)
        sync.observe("I was waiting for you at the station for two hours", speechEndedAt: wall(66, anchor: t0))
        sync.pause(at: wall(66.5, anchor: t0))
        #expect(sync.status(at: wall(90, anchor: t0)) == .paused(videoTime: 66.5))
        sync.resume(at: wall(96.5, anchor: t0)) // paused for 30 s
        let time = try #require(sync.videoTime(at: wall(97, anchor: t0)))
        #expect(abs(time - 67) < 0.01)
    }

    @Test func matchesLanguagesWithoutSpaces() {
        let korean = [SubtitleCue(start: 10, end: 12, text: "역에서 두 시간 동안 너를 기다렸어.")]
        let sync = SubtitleSync(cues: korean)
        sync.observe("역에서 2시간 동안 너를 기다렸어", speechEndedAt: t0) // recognizer wrote the number as a digit
        sync.observe("역에서 두 시간 동안 너를 기다렸어", speechEndedAt: t0)
        #expect(sync.isSynced)
    }

    @Test func diceSimilarity() {
        let a = SubtitleSync.bigrams(SubtitleSync.normalize("Night, night!"))
        #expect(SubtitleSync.dice(a, a) == 1)
        #expect(SubtitleSync.dice(a, SubtitleSync.bigrams("xyz")) == 0)
        #expect(SubtitleSync.normalize("<i>Hello,</i>  World!") == "ihelloiworld" || SubtitleSync.normalize("Hello,  World!") == "helloworld")
    }

    @Test func digitalSilenceMeansPaused() {
        let detector = PlaybackSilenceDetector(seconds: 0.2)
        let changes = Recorder<Bool>()
        detector.onChange = { silent, _ in changes.append(silent) }
        detector.append(Audio.tone(0.5))
        detector.append(Audio.silence(0.3)) // paused
        detector.append(Audio.tone(0.1, amplitude: 0.001)) // quiet scene, not silence
        #expect(changes.values == [true, false])
    }
}

@Suite struct SubtitleSourcesTests {
    @Test func parsesDotEnvFiles() {
        let values = Secrets.parse("""
        # OpenSubtitles
        OPENSUBTITLES_API_KEY=abc123
        export OPENSUBTITLES_USERNAME="isaac"
        OPENSUBTITLES_PASSWORD='p#ss word' # quoted keeps the hash
        EMPTY=
        not a line
        """)
        #expect(values["OPENSUBTITLES_API_KEY"] == "abc123")
        #expect(values["OPENSUBTITLES_USERNAME"] == "isaac")
        #expect(values["OPENSUBTITLES_PASSWORD"] == "p#ss word")
        #expect(values["EMPTY"] == "")
    }

    @Test func parsesOpenSubtitlesSearchResults() throws {
        let json = """
        {"total_count": 2, "data": [
          {"id": "9001", "type": "subtitle", "attributes": {"language": "en", "download_count": 1234,
            "release": "Parasite.2019.1080p.BluRay",
            "feature_details": {"title": "Parasite", "year": 2019},
            "files": [{"file_id": 42, "file_name": "Parasite.2019.en.srt"}]}},
          {"id": "9002", "type": "subtitle", "attributes": {"language": "ko", "download_count": 7,
            "release": "", "feature_details": {"title": "Episode 5", "parent_title": "Squid Game", "year": 2021,
              "season_number": 1, "episode_number": 5},
            "files": [{"file_id": 43, "file_name": "sg.s01e05.srt"}]}},
          {"id": "bad", "attributes": {"files": []}}
        ]}
        """
        let results = try OpenSubtitlesClient.parseSearch(Data(json.utf8))
        #expect(results.count == 2)
        #expect(results[0] == SubtitleSearchResult(id: "9001", fileID: 42, fileName: "Parasite.2019.en.srt", title: "Parasite",
                                                   year: 2019, language: "en", release: "Parasite.2019.1080p.BluRay",
                                                   downloads: 1234, episode: nil))
        #expect(results[1].title == "Squid Game")
        #expect(results[1].episode == "S01E05")
        #expect(OpenSubtitlesClient.apiLanguage("zh") == "zh-cn")
    }

    @Test func detectsASubtitleFilesLanguage() {
        let cues = ["밤새 어디 있었어?", "역에서 두 시간 동안 너를 기다렸어.", "걱정 마, 형이 집까지 데려다줄 거야."]
            .enumerated().map { SubtitleCue(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) }
        #expect(SubtitleLanguage.detect(cues) == "ko")
    }

    @Test func reusesAnEarlierTranslationOfTheSameFile() throws {
        let folder = try makeTemporaryDirectory()
        let english = folder.appendingPathComponent("Movie.en.srt")
        let cues = [SubtitleCue(start: 1, end: 2, text: "Hi."), SubtitleCue(start: 3, end: 4, text: "Bye.")]
        try SubtitleFile.srt(cues).write(to: english, atomically: true, encoding: .utf8)
        let burmese = [SubtitleCue(start: 1, end: 2, text: "မင်္ဂလာပါ"), SubtitleCue(start: 3, end: 4, text: "တာ့တာ")]
        try SubtitleFile.srt(burmese).write(to: folder.appendingPathComponent("Movie.my.srt"), atomically: true, encoding: .utf8)

        #expect(SyncTranslations.existingTranslations(for: english, cues: cues, target: "my") == [0: "မင်္ဂလာပါ", 1: "တာ့တာ"])
        #expect(SyncTranslations.existingTranslations(for: english, cues: cues, target: "th").isEmpty)
    }
}
