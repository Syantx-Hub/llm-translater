# 3. Voice activity detection (VAD)

What you'll learn: how to tell speech from silence, music and noise; why a small neural
network beats a loudness threshold; and how to cut a continuous stream into utterances.

## Concepts

**Why segment at all?** Whisper transcribes a fixed window of audio, not a stream. We need
to decide *which* audio to hand it: ideally one sentence, starting just before the first
syllable and ending right after the last. Cutting too early splits sentences; waiting too
long adds lag.

**Energy VAD.** The simplest detector: frame energy = mean of squared samples; "speech" when
it's well above the background (noise floor). It is cheap and works in a quiet room. It
fails in films: a music bed or crowd noise is as loud as dialogue, so the detector never
sees a pause.

**Neural VAD (Silero).** A tiny model (~2 MB) trained to output P(speech) for each 32 ms
frame. It has learned what speech *looks like* in the spectrum (harmonics of a voice,
syllable rhythm), not just how loud it is. It's recurrent: an LSTM carries state from
frame to frame, so it sees context. It runs in well under a millisecond per frame on CPU.

**Hysteresis.** A single threshold flickers on a borderline signal. Two thresholds fix
that: switch *on* above 0.5, switch *off* only below 0.35.

**ONNX Runtime.** ONNX is a portable model format; ONNX Runtime is a library that runs it.
You feed named tensors in and get tensors out. It's the easiest way to run a PyTorch-born
model from Swift.

## How Subtitler does it

### Silero (`SileroVAD`)

- Input per call: 512 new samples (32 ms at 16 kHz) plus the previous 64 samples as
  context, a `[2, 1, 128]` LSTM state and the sample rate.
- Output: a speech probability and the new state, which is fed into the next call.
- Speech starts above 0.5 and ends below 0.35.
- The model is bundled (`Resources/silero_vad.onnx`, MIT). If it fails to load, the
  segmenter falls back to the energy detector. Both conform to `SpeechDetector`, so the
  segmenter doesn't care which one it has, and tests can use the deterministic energy one.

**Measured:** on a clip with constant background sound, the energy VAD found no pauses and
merged five sentences into one 9 s utterance. Silero found all five, each ending within
0.1 s of the real end of speech. That one change fixed "captions stop in films".

### The segmenter (`SpeechSegmenter`)

A state machine over detector frames:

1. **Idle.** Keep the last 300 ms of audio as a *pre-roll*.
2. **Speech onset.** Start the utterance with the pre-roll so the first consonant isn't
   clipped.
3. **In an utterance:**
   - after ~120 ms of silence: emit a **pause draft** `.partial(samples, isPause: true)`;
   - every `draftEvery` of new audio: emit a regular draft;
   - after `endSilence` of silence: emit `.final(samples, trailingSilence:)`, if there
     were at least 240 ms of speech (shorter blips are dropped);
   - at `maxSeconds`: cut at the quietest frame of the last 3 s, not mid-word, and carry
     the rest into the next utterance.
4. (Energy detector only) If even the quietest frame of the last 3 s is "speech", that's
   steady music, so the noise floor rises towards it.

| Preset | `endSilence` | `draftEvery` | `maxSeconds` |
|---|---|---|---|
| Fast | 360 ms | 500 ms | 6 s |
| Balanced (default) | 480 ms | 700 ms | 9 s |
| Accurate | 700 ms | 1000 ms | 14 s |

`trailingSilence` matters for the latency trick in
[the live pipeline](05-live-pipeline-and-latency.md): if the final is just the pause draft
plus silence, the draft's result can be reused.

The segmenter always runs, even with Apple Speech (which does its own endpointing): there
it reports pauses so a line can be committed sooner, and it feeds language detection.

## Try it

```sh
say -o /tmp/test.aiff "Where have you been all night? I waited for hours."
SUBTITLER_TRACE=1 app/build/Subtitler.app/Contents/MacOS/Subtitler \
  --file /tmp/test.aiff --translator off --realtime
```

The trace shows each draft and final with its sample count. Try `--responsiveness fast`
and `accurate` and watch how the utterances change.

## Code map

- `app/Sources/Subtitler/Audio/SileroVAD.swift`: Silero model, `SpeechDetector`, energy detector
- `app/Sources/Subtitler/Audio/SpeechSegmenter.swift`: the state machine and presets
- Tests: `SpeechSegmenterTests` (blips, pause draft covers all speech, long speech split, music)

## Further reading

- Silero VAD: https://github.com/snakers4/silero-vad
- ONNX Runtime: https://onnxruntime.ai
