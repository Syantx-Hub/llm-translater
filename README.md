# llm_translater

Offline live-translation subtitle overlay for Apple Silicon Macs (M1 and later).
Burmese is the primary subtitle language; other languages are supported too.

Current stage: step 1, a feasibility eval that turns a media file into translated
subtitles so model quality and latency can be compared.

## Requirements

- Apple Silicon Mac (any M-series chip), macOS 14+
- Python 3.10+
- 8 GB RAM minimum; 16 GB+ to run MADLAD without conversion

## Setup

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

No ffmpeg needed: audio is decoded with PyAV.

## Run

```sh
python eval.py clip.mp4 --source en                 # EN -> Burmese, NLLB + MADLAD
python eval.py clip.mp4 --source ko --models nllb   # KO -> Burmese, NLLB only
python eval.py clip.mp4 --source ja --target th     # JA -> Thai
```

`--source` is auto-detected when omitted. Supported codes: `my en ko ja zh th vi id ms
hi fr es de pt ru ar`. Burmese as a *source* works but Whisper's Burmese ASR is weak.

Output goes to `outputs/<clip>/`: `source.<lang>.srt`, `<model>.<target>.srt`,
`segments.json`, and `comparison.md` (side-by-side table plus hardware and latency
summary).

## Pipeline

PyAV decode → Silero VAD (only speech reaches Whisper, which prevents hallucinations on
silence and music) → MLX Whisper `large-v3-turbo` on the GPU → NLLB-200 / MADLAD-400.

## MADLAD on 8 GB Macs

MADLAD-400 3B needs ~6 GB in bf16 and will swap on 8 GB. Convert it once to
CTranslate2 int8 (~3 GB) and pass the path:

```sh
ct2-transformers-converter --model google/madlad400-3b-mt \
    --quantization int8 --low_cpu_mem_usage --output_dir models/madlad400-3b-ct2
python eval.py clip.mp4 --madlad-ct2 models/madlad400-3b-ct2
```

The conversion reads the full checkpoint, so close other apps while it runs.

## Licensing

Whisper: MIT. MADLAD-400: Apache 2.0. NLLB-200: CC-BY-NC, so it is for evaluation and
portfolio use only, not for a commercial release.
