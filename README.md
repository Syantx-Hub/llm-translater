# Subtitler

Offline live subtitles for Apple Silicon Macs (M1 and later). Subtitler listens to whatever
your Mac is playing and shows subtitles in a floating, click-through overlay — including
over full-screen video. It can translate (Burmese first, 15 other languages) or just
transcribe the original words.

The app ships with no models. On first launch a setup window walks through choosing and
downloading a speech model and a translation model; the **Models** window lets you
download, switch and delete them later.

For how it all works inside, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Features

- **Translate or transcribe only** — pick the mode in the main window.
- **Caption styling** (Captions window) — font, weight, size, line spacing, colours,
  outline/shadow, background, position, width, lines on screen and how long lines stay.
  A live preview, plus "Preview on screen", shows every change as you make it.
- **Responsiveness** — Fast, Balanced or Accurate: how long a pause ends a line and how
  long a line may get. The main window shows the current lag while live.
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

The default build is ad-hoc signed, so macOS asks again after each rebuild. To keep the
grant, create a self-signed "Code Signing" certificate in Keychain Access and build with
`SIGN_IDENTITY="<its name>" scripts/build-app.sh`. To reset the permission:

```sh
tccutil reset AudioCapture com.syantxhub.subtitler     # System Audio Recording
tccutil reset ScreenCapture com.syantxhub.subtitler    # Screen Recording (14.0–14.1 only)
```

## Pipeline

Core Audio tap (16 kHz mono) → energy VAD segmenter → WhisperKit on the Neural Engine →
MADLAD-400 via llama.cpp on the GPU → overlay.

The segmenter sends a draft whenever the speaker pauses and at regular intervals while
they talk. Drafts are transcribed and translated immediately and shown in a lighter
colour. When the pause turns out to be the end of the line, the final reuses that draft's
text and translation instead of decoding again, so the line appears almost as soon as the
speaker stops. Translation runs sentence by sentence with a repetition guard.

| Stage | Models | License |
|---|---|---|
| Speech | Whisper Large v3 Turbo (default), Turbo compact, Large v3, Small, Distil-Large v3 (English) | MIT |
| Translation | MADLAD-400 3B Q4_K_M (default), Q8_0 | Apache 2.0 |

Models live in `~/Library/Application Support/Subtitler/Models`. Downloads go to a
staging folder and move into place only when complete; deleting a model removes its
files and caches. CoreML also keeps a compiled-model cache in
`~/Library/Caches/com.syantxhub.subtitler`, which macOS may clear at any time.

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
$Subtitler --audio-probe          # permission status + 3 s capture level (never prompts)
$Subtitler --snapshot /tmp/ui     # renders every window to PNGs, light and dark
```

`--file` options: `--model <speech id>`, `--translator <model id | sidecar:nllb | off>`,
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
