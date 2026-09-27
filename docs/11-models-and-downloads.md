# 11. Models and downloads

What you'll learn: shipping an app with no models, choosing model sizes for the hardware,
and downloading multi-GB files without ever leaving a broken model on disk.

## Concepts

**Pick models for the hardware.** 8 GB Macs are the floor. Rules of thumb: the model's
file size ≈ its memory use; leave room for the OS and the video player.

**Atomic installs.** Download to a staging folder, validate, then *move* into place (a move
within one disk is atomic). A crash mid-download can never produce a half-installed model.

**Locks.** Two windows or processes downloading the same model at once corrupt it. A
`flock` file lock per model prevents that.

## How Subtitler does it

| Speech | Size | Notes |
|---|---|---|
| Apple Speech | built in | macOS 26; 9 languages; nothing to download |
| Whisper Large v3 Turbo (fast) | 632 MB | **Recommended**; ~0.6 s per line on M2 |
| Whisper Large v3 Turbo | 1.6 GB | |
| Turbo (compact) | 627 MB | |
| Large v3 | 3.1 GB | most accurate, 16 GB+ |
| Small | 486 MB | fast, weaker on accents |
| Distil-Whisper Large v3 | 1.5 GB | English only |

| Translation | Size | Notes |
|---|---|---|
| MADLAD-400 3B Q4_K_M | 1.9 GB | **recommended for live Translate**: fastest; one sentence at a time, no context |
| MADLAD-400 3B Q8_0 | 3.1 GB | better wording; recommended with 16 GB+ |
| Gemma 4 E2B Q4_0 | 2.8 GB | **default; recommended for movies**: on-device LLM with context; fits 8 GB |
| Gemma 4 E4B Q4_0 | 4.6 GB | needs 8 GB, 16 GB recommended |
| Gemma 4 12B Q4_0 | 7.2 GB | needs 16 GB, 24 GB recommended |
| Gemma 4 26B-A4B Q4_0 | 14.6 GB | MoE, quick for its size; needs 24 GB, 32 GB recommended |
| Gemma 4 31B Q4_0 | 18 GB | needs 32 GB, 48 GB recommended |

**Memory fit.** Every card says what the model needs and whether this Mac has it
(`ModelInfo.fit`, `MemoryFit`): *Runs well* at or above the recommended RAM, *May run
with other apps closed* between the minimum and the recommended, *Too big* below the
minimum. The minimum is where the file still loads into GPU memory, which macOS caps
at about two thirds of RAM, plus room for the context and the speech model; the
recommended amount leaves space for a browser. They're estimates, not measurements,
except E2B, which was run on an 8 GB M2. Every model can still be downloaded, so a
library can be set up for another Mac.

**Download (`ModelFiles.download`):**
1. Take the per-model `flock`; if held, fail with "busy".
2. Download into `.staging/<id>-<uuid>/`. WhisperKit: the CoreML folder, then the tokenizer
   copied *into* the model folder (works offline, deleted with it). GGUF: HTTP 200 and
   the `GGUF` magic bytes.
3. Validate every required file is non-empty (`coremldata.bin`, `model.mil`,
   `weights/weight.bin` per `.mlmodelc`, `config.json`), then write `.complete`.
4. Move into place. Abandoned staging folders are cleaned at launch.

This fixed a real bug: a download race once left `weight.bin` missing and the model
failed to load.

**Delete** takes the same lock and removes the model and its caches.

**`ModelStore`** is the UI state: status per model, attempt UUIDs so progress from a
cancelled attempt is ignored, auto-selection of an installed model, `inUse` protection
during a session.

```
~/Library/Application Support/Subtitler/Models/
  speech/models/argmaxinc/whisperkit-coreml/<variant>/
  translation/<file>.gguf
  .staging/  .<id>.lock
```

`SUBTITLER_MODELS_DIR` overrides the location (used by tests and experiments).

## Code map

- `app/Sources/Subtitler/Models/ModelCatalog.swift`, `ModelFiles.swift`, `ModelStore.swift`
- `app/Sources/Subtitler/UI/ModelsView.swift`, `ModelCard.swift`, `WelcomeView.swift`
- Tests: `ModelFilesTests` (install detection, delete removes files and caches, locks, staging)
