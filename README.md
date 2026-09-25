# Subtitler

Offline live-translation subtitles for Apple Silicon Macs (M1 and later). Subtitler
listens to whatever your Mac is playing and shows translated subtitles in a floating,
click-through overlay — including over full-screen video. Burmese is the primary
subtitle language; 15 others are supported.

The app ships with no models. On first launch a setup window walks through choosing and
downloading a speech model and a translation model; the **Models** window lets you
download, switch and delete them later.

## Requirements

- Apple Silicon Mac (any M-series chip), macOS 14+
- 8 GB RAM minimum
- Command Line Tools (`xcode-select --install`); Xcode is not required

## Build and run

```sh
scripts/build-app.sh            # builds app/build/Subtitler.app
open app/build/Subtitler.app    # appears in the menu bar
```

The first Start asks for the Screen Recording permission, which is how macOS lets apps
hear system audio. The build is ad-hoc signed, so after a rebuild you may need to
re-enable Subtitler in System Settings › Privacy & Security › Screen Recording.

## Pipeline

ScreenCaptureKit system audio (16 kHz mono) → energy VAD segmenter (drafts every second,
finals at pauses) → WhisperKit on the Neural Engine → MADLAD-400 via llama.cpp on the GPU
→ overlay. Draft text shows in grey while speech is in progress; the translated line
replaces it.

| Stage | Models | License |
|---|---|---|
| Speech | Whisper Large v3 Turbo (default), Turbo compact, Large v3, Small, Distil-Large v3 (English) | MIT |
| Translation | MADLAD-400 3B Q4_K_M (default), Q8_0 | Apache 2.0 |

Models are stored in `~/Library/Application Support/Subtitler/Models`.

## Headless testing

Run an audio file through the same pipeline, no permission needed:

```sh
say -o /tmp/test.aiff "Where have you been all night?"
app/build/Subtitler.app/Contents/MacOS/Subtitler --file /tmp/test.aiff --source en --target my
```

Options: `--model <speech id>`, `--translator <model id | sidecar:nllb | off>`,
`--realtime` (feed at playback speed). Missing models are downloaded first.

`--snapshot DIR` renders every window to PNGs in light and dark mode.

## Python tools (`python/`)

- `eval.py` — offline eval: media file → Silero VAD → MLX Whisper → NLLB / MADLAD, with
  per-line latency and a side-by-side `comparison.md`.
- `translate_server.py` — JSON-lines translation sidecar. Development builds can pick it
  under Models › Developer engine, e.g. to compare NLLB-200 against MADLAD.

```sh
cd python && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python eval.py clip.mp4 --source en
```

NLLB-200 is CC-BY-NC: for evaluation only, never in a commercial release.
