# 10. Subtitle files and OpenSubtitles

What you'll learn: subtitle formats, batch translation, and integrating a real REST API
safely (secrets, quirks, ranking).

## Subtitle files

**Formats.** SubRip (`.srt`): numbered blocks, `00:01:02,500 --> 00:01:04,000`, text.
WebVTT (`.vtt`): a `WEBVTT` header, `.` for milliseconds, optional cue IDs and settings.

`SubtitleFile` reads both: UTF-8, UTF-16 or Windows-1252, with or without BOM, CRLF,
malformed blocks skipped. It writes SubRip.

**Save Translated Copy…** (Subtitle file mode): `SubtitleTranslator` translates each cue's
plain text (tags like `<i>`, `{\an8}` and line breaks removed) sentence by sentence.
Cues that split one sentence are joined (see [Subtitle sync](09-subtitle-sync.md)) and
written as one cue spanning them; other cues keep their timing. Repeated lines ("Yes.") are translated once. The output is
`Movie.en.srt` → `Movie.my.srt` next to the original, which players load automatically;
nothing is overwritten (`Movie.my 2.srt`). ~0.5 s per line on an M2, so a 1,000-line film
takes 8–10 min. Disabled during a live session (both would load the ~2 GB model).

## OpenSubtitles

**The API.** REST + JSON at `api.opensubtitles.com/api/v1`, with an `Api-Key` header.
`/subtitles` searches, `/download` returns a temporary link. An optional login raises the
daily download limit.

**Quirk:** the API answers **301** unless query parameters are **sorted by name, values
lowercased, spaces sent as `+`**. `OpenSubtitlesClient.url` builds URLs that way; tests
pin it.

**TV episodes.** Searching "breaking bad" + episode numbers directly returned films
(El Camino). Fix: `SubtitleQuery.parse` recognizes "s01e01", "1x01", "season 1 episode 1"
(or the TV episode toggle), then:

1. `/features?type=tvshow&query=…` → the show's ID;
2. `/subtitles?parent_feature_id=…&season_number=…&episode_number=…&type=episode`.

**Ranking:** API relevance order is kept across titles; within a title, the requested
episode first, then WEB-DL/BluRay, then download count. Files are saved as
"Breaking Bad S01E01.en.srt" / "Parasite (2019).ko.srt" under
`~/Library/Application Support/Subtitler/Subtitles`.

**Secrets (`Secrets`).** Read in order: environment variable →
`~/Library/Application Support/Subtitler/.env` → repo `.env` (`--dev` builds only).
`.env` is git-ignored; the key is only sent to api.opensubtitles.com and never logged.

**Why no OpenSubtitles AI translation:** its translation API doesn't offer Burmese, so the
offline MADLAD path stays.

## Try it

```sh
Subtitler=app/build/Subtitler.app/Contents/MacOS/Subtitler
$Subtitler --search-subtitles "breaking bad s01e01" --language en
$Subtitler --translate-subtitles Movie.en.srt --target my
```

## Code map

- `app/Sources/Subtitler/Subtitles/SubtitleFile.swift`, `SubtitleTranslator.swift` (`SubtitleJob`, `SubtitleRunner`, `SubtitleSearchRunner`)
- `app/Sources/Subtitler/Subtitles/OpenSubtitles.swift`, `Secrets.swift`
- `app/Sources/Subtitler/UI/SubtitleSearchView.swift`, `SubtitleFileView.swift`
- Tests: `SubtitleFileTests`, `SubtitleSourcesTests` (canned API JSON, URL format, episode parsing, ranking, `.env` parsing)

## Further reading

- OpenSubtitles API docs: https://opensubtitles.stoplight.io/docs/opensubtitles-api
