# 1. Architecture

What you'll learn: how a real-time AI app is structured so that slow model calls never
freeze the UI or corrupt each other, and why "sessions" need IDs.

## Concepts

**Real-time AI apps are mostly plumbing.** The models (speech recognition, translation) are
a few function calls. The hard part is feeding them audio continuously, running them off
the main thread, keeping results in order, and cancelling cleanly when the user stops.

**Actors.** Swift's `actor` is a type whose methods run one at a time, like a class with a
private queue. Model wrappers are actors so two callers can't use the same model at once.
Beware *reentrancy*: while an actor method is `await`ing, other calls can run. Code that
reads state before an `await` must not assume it's unchanged afterwards.

**One ordered stream between threads.** Audio arrives on an audio thread. To hand events to
an actor in order, the app pushes them into an `AsyncStream` and one task reads the stream.
Spawning a new `Task` per event would not preserve order.

## How Subtitler does it

### The parts

| Part | Role |
|---|---|
| `SubtitlerApp` | Entry point, windows (menu bar panel, main, welcome, captions, models, find subtitles, translate) |
| `AppState` (main actor) | Owns a live session and everything the UI shows |
| `ModelStore` | What's installed, downloading and selected |
| `CaptionStyle` | How captions look (persisted) |
| `SubtitlePipeline` (actor) | Turns speech into caption lines: recognition, translation, ordering |
| `Transcriber` / `AppleSpeechRecognizer` | Speech recognition engines |
| `LlamaTranslator` (actor) | Translation engine |
| `SubtitleSync` | Follows a subtitle file along with the video |

`Entry.main()` also handles headless modes (`--file`, `--snapshot`, `--audio-probe`,
`--translate-subtitles`, `--search-subtitles`), which is how most of the measurements in
these docs were taken; see [Build, test and debug](12-build-test-debug.md).

### A session

`AppState.start()` runs `run(id)`:

1. Choose the speech engine (Whisper or Apple Speech; see
   [Speech recognition](04-speech-recognition.md)) and load it.
2. Start the translator (translate and subtitle-file modes).
3. Build a `SubtitlePipeline` and a `SpeechSegmenter` (with Silero VAD).
4. Start audio capture. Its samples go through a `SampleRouter`, which can fan them out to
   several consumers and be re-pointed mid-session (e.g. from Whisper to Apple Speech).
5. `phase = .running`, show the overlay.

### Session IDs

Every start, stop and failure increments `AppState.session`. Async work carries the ID it
started with and checks it after each `await` (`checkSession`), and pipeline updates
arrive as `apply(update, session: id)`. Without this, pressing Stop then Start quickly let
the old session's cleanup tear down the new one; three review agents found that race.

### Resources

Everything a session owns (pipeline, capture, translator, event pumps, recognizer) lives in
one `Resources` struct. `endSession()` takes it out of `AppState` *before* any `await` and
releases it in the background, so a new session never shares state with a dying one.

### Per-session settings

Mode and languages are snapshotted when a session starts and the pickers are disabled
while it runs. Models in use (`ModelStore.inUse`) can't be deleted or swapped mid-session.

### Settings

Stored in `UserDefaults` (`com.syantxhub.subtitler`):

| Key | Meaning |
|---|---|
| `sourceLanguage` | Spoken language or `auto` |
| `targetLanguage` | Subtitle language (default `my`) |
| `mode` | `translate` / `transcribe` / `synced` (Subtitle file) |
| `responsiveness` | `fast` / `balanced` / `accurate` |
| `appleAutoHandover` | Auto-detect starts on Whisper and hands over to Apple Speech |
| `hidesUnclearLines` | Hide low-confidence lines |
| `selectedSpeech` / `selectedTranslation` | Model IDs (`ModelStore`) |
| `caption.*` | Caption appearance (`CaptionStyle`) |

## Code map

- `app/Sources/Subtitler/SubtitlerApp.swift`: entry, scenes, `WindowRouter`
- `app/Sources/Subtitler/AppState.swift`: sessions, engine choice, sync mode glue
- `app/Sources/Subtitler/SubtitlePipeline.swift`: the pipeline actor

## Further reading

- Swift concurrency, actors and reentrancy: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
