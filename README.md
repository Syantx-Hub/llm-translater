# Subtitler

Offline live subtitles for Apple Silicon Macs (M1 and later). Subtitler listens to whatever
your Mac is playing and shows subtitles in a floating, click-through overlay — including
over full-screen video. It can translate (Burmese first, 15 other languages) or just
transcribe the original words.

The app ships with no models. On first launch a setup window walks through choosing and
downloading a speech model and a translation model; the **Models** window lets you
download, switch and delete them later.

For how it all works inside, and the AI concepts behind each part, see [docs/](docs/README.md): one page per feature.

## Features

- **Two speech engines** — Apple Speech (macOS 26, built in) shows words as they're
  spoken, for English, Korean, Japanese, Chinese, French, German, Spanish and Portuguese.
  Whisper covers every other language and Auto-detect.
- **Translate or transcribe only** — pick the mode in the main window. Translate mode
  shows each line once the sentence is finished.
- **Save a translated copy** — in Subtitle file mode, "Save Translated Copy…" writes the
  file translated next to the original (`Movie.en.srt` → `Movie.my.srt`), which players
  load automatically. Because it's done
  ahead of time, the subtitles appear exactly when the actors speak.
- **Subtitle file mode (synced)** — pick the subtitles for what you're watching (a file,
  or found on OpenSubtitles), press Start while the video plays, and Subtitler finds its
  place by matching what it hears to the file's lines. Lines then show translated on the
  file's own timing — with the actor, not after — including on streaming services.
  Pausing and skipping are followed.
- **Auto-detect follows the video** — switch to a video in another language and the
  session switches with it.
- **Caption styling** (Captions window) — font, weight, size, line spacing, colours,
  outline/shadow, background, position, width, lines on screen and how long lines stay.
  A live preview, plus "Preview on screen", shows every change as you make it.
- **Responsiveness** — Fast, Balanced or Accurate: how long a pause ends a line and how
  long a line may get. The main window shows the current lag while live.
- **Guided** — a tour explains the three ways to use it; every setting says what it's
  for, and a live preview shows what each mode puts on screen.
- **Optional cloud translation** — OpenAI, Anthropic, Gemini, Mistral, DeepSeek, Groq,
  OpenRouter, or a local Ollama / LM Studio, with your own key (kept in the Keychain).
  Best for subtitle files: translated in context, cached next to the file. Offline MADLAD
  stays the default; nothing is sent unless you choose a cloud engine. See
  [docs/14-cloud-translation.md](docs/14-cloud-translation.md).
- **Private** — audio never leaves the Mac and is never stored.

## Requirements

- Apple Silicon Mac, macOS 14+ (14.2+ recommended, see Permissions)
- 8 GB RAM minimum
- Command Line Tools (`xcode-select --install`); Xcode is not required

## Build and run

```sh
scripts/build-app.sh                  # builds app/build/Subtitler.app
open app/build/Subtitler.app          # the main window opens; the icon lives in the menu bar
scripts/build-app.sh release --dev    # also enables the Python developer engines (see below)
```

Rebuilding replaces the app in place; quit the running copy first (menu bar icon › Quit).

### Permissions

On macOS 14.2+ Subtitler hears system audio through a Core Audio process tap, which
needs only **System Audio Recording** (System Settings › Privacy & Security › Screen &
System Audio Recording). It never sees your screen. macOS 14.0–14.1 has no audio taps,
so there it falls back to ScreenCaptureKit, which needs Screen Recording.

An ad-hoc signed build looks like a new app to macOS after every rebuild, so it asks for
permissions again (audio, and access to API keys in the Keychain). Run
`scripts/make-dev-cert.sh` once: it creates a local "Subtitler Dev" signing certificate,
which `build-app.sh` then uses automatically, so macOS asks once and remembers. (Or set
`SIGN_IDENTITY` to any code-signing identity.) To reset the permission:

```sh
tccutil reset AudioCapture com.syantxhub.subtitler     # System Audio Recording
tccutil reset ScreenCapture com.syantxhub.subtitler    # Screen Recording (14.0–14.1 only)
```

## Pipeline

Core Audio tap (16 kHz mono) → Silero VAD segmenter → Whisper (WhisperKit) or Apple Speech →
MADLAD-400 via llama.cpp on the GPU (or an optional cloud LLM) → overlay.

The segmenter sends a draft whenever the speaker pauses and at regular intervals while
they talk. Drafts are transcribed and translated immediately and shown in a lighter
colour. When the pause turns out to be the end of the line, the final reuses that draft's
text and translation instead of decoding again, so the line appears almost as soon as the
speaker stops. Translation runs sentence by sentence with a repetition guard.

| Stage | Models | License |
|---|---|---|
| Voice activity | Silero VAD (bundled) | MIT |
| Speech | Apple Speech (built in, macOS 26), Whisper Large v3 Turbo, Turbo compact, Large v3, Small, Distil-Large v3 (English) | Apple / MIT |
| Translation | MADLAD-400 3B Q4_K_M (default), Q8_0 | Apache 2.0 |

Models live in `~/Library/Application Support/Subtitler/Models`. Downloads go to a
staging folder and move into place only when complete; deleting a model removes its
files and caches. CoreML also keeps a compiled-model cache in
`~/Library/Caches/com.syantxhub.subtitler`, which macOS may clear at any time.

## OpenSubtitles API key

Searching OpenSubtitles needs a free API key from
https://www.opensubtitles.com/en/consumers. Put it in a `.env` file (see `.env.example`):

- `~/Library/Application Support/Subtitler/.env` — works for every build, or
- `.env` in the repo root — read by `scripts/build-app.sh --dev` builds.

```
OPENSUBTITLES_API_KEY=your-key
# optional, raises the daily download limit:
OPENSUBTITLES_USERNAME=you
OPENSUBTITLES_PASSWORD=secret
```

The key is only sent to api.opensubtitles.com and is never logged.

## Tests

```sh
cd app && swift test                                   # unit + integration tests
SUBTITLER_E2E=1 swift test --filter endToEnd           # full pipeline with installed models
python3 -m unittest discover -s python/tests           # sidecar protocol
```

The Swift tests cover the VAD segmenter, the pipeline (draft reuse, ordering, failures,
cancellation, transcribe-only), model install/delete on disk, caption settings, and the
sidecar protocol over a real Python process.

## Developer tools

```sh
say -o /tmp/test.aiff "Where have you been all night?"
Subtitler=app/build/Subtitler.app/Contents/MacOS/Subtitler
$Subtitler --file /tmp/test.aiff --source en --target my --realtime   # headless run, prints lag
$Subtitler --file /tmp/test.aiff --responsiveness fast --translator off
$Subtitler --translate-subtitles Movie.en.srt --target my             # translate a subtitle file
$Subtitler --search-subtitles "breaking bad s01e01" --language en     # search OpenSubtitles (.env key)
$Subtitler --audio-probe          # permission status + 3 s capture level (never prompts)
$Subtitler --snapshot /tmp/ui     # renders every window to PNGs, light and dark
```

`--file` options: `--model <speech id | apple-speech>`, `--translator <model id | sidecar:nllb | off>`,
`--responsiveness fast|balanced|accurate`, `--realtime`. Missing models are downloaded first.

## Python tools (`python/`)

- `eval.py` — offline eval: media file → Silero VAD → MLX Whisper → NLLB / MADLAD, with
  per-line latency and a side-by-side `comparison.md`.
- `translate_server.py` — JSON-lines translation sidecar. `--dev` builds can pick it under
  Models › Developer engine, e.g. to compare NLLB-200 against MADLAD.

```sh
cd python && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python eval.py clip.mp4 --source en
```

NLLB-200 is CC-BY-NC: for evaluation only, never in a commercial release.
