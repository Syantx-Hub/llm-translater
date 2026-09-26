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
| MADLAD-400 3B Q4_K_M | 1.9 GB | default; recommended under 16 GB RAM |
| MADLAD-400 3B Q8_0 | 3.1 GB | better wording; recommended with 16 GB+ |

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
