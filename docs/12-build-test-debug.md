# 12. Build, test and debug

What you'll learn: how the app is built without Xcode, how AI code is tested without
running models, and the headless tools used to measure everything in these docs.

## Build

`scripts/build-app.sh [release|debug] [--dev] [--open]`:

1. `swift build --arch arm64`.
2. Assemble `Subtitler.app`: executable, `llama.framework` (thinned to arm64), SwiftPM
   resource bundles (the Silero model), icon, Info.plist.
3. `--dev` adds `SubtitlerRepoRoot` to Info.plist (repo `.env`, Python sidecar).
4. Sign inside-out (framework, then app). Ad-hoc by default, or `SIGN_IDENTITY`. macOS ties
   permissions to the signature, so a stable identity keeps the audio permission.

Gotchas that cost time:
- `swift-collections` is pinned < 1.4: newer versions crash at launch with
  `Symbol not found: _swift_initBorrow`.
- Command Line Tools lack the SwiftUI `@State` macro, so views use `@StateObject`.
- The Swift Testing macro plugin needs `-plugin-path` (set in `Package.swift`).

## Test

```sh
cd app && swift test                              # 111 tests, a few seconds
SUBTITLER_E2E=1 swift test --filter endToEnd      # real models, slow
python3 -m unittest discover -s python/tests      # sidecar protocol (6 tests)
```

**Testing AI code without models.** Everything model-shaped is behind a protocol
(`SpeechTranscribing`, `Translator`, `SpeechDetector`, `AudioCapture`). Tests use fakes:

- `FakeTranscriber` returns text by sample count, so draft reuse is checkable (was the
  final decoded again or not?).
- `FakeTranslator` adds a prefix and can be slow or fail, to test ordering and fallbacks.
- Energy VAD with synthetic tones makes segmenter tests deterministic.
- OpenSubtitles tests parse canned JSON responses and check built URLs; they never touch the network or the key.
- Model tests point `ModelFiles.rootOverride` at a temp folder.

Suites: SpeechSegmenter, SubtitlePipeline, ModelFiles, CaptionStyle / SampleCaption /
CaptionSlot, Integration, LlamaTranslator, SubtitleFile / SubtitleTranslator,
SubtitleSync / SubtitleSources.

## Debug and measure

| Tool | Use |
|---|---|
| `--file AUDIO [--realtime]` | Run a file through the real pipeline; prints drafts, lines and lag |
| `SUBTITLER_TRACE=1` | Timings for each decode, draft reuse, queue waits (works in the app too) |
| `--audio-probe` | Permission status + 3 s capture level |
| `--snapshot DIR` | Render all windows to PNG |
| `--translate-subtitles FILE --target xx` | Batch-translate a subtitle file |
| `--search-subtitles "QUERY" --language xx` | OpenSubtitles search |
| `python/eval.py` | Offline eval: Silero → MLX Whisper → NLLB/MADLAD, side-by-side comparison |

`say -v <voice>` makes test speech in many languages; `ffmpeg` mixes in noise or music to
make it film-like. Most design decisions in these docs came from exactly that loop:
make a clip → run `--file` with the trace → change one thing → compare.
