# 4. Speech recognition (ASR)

What you'll learn: how Whisper turns audio into text, what makes one model variant faster
than another, how streaming recognizers differ, and how to run models on Apple's Neural
Engine.

## Concepts

### Audio → features

Models don't read raw samples. Audio is turned into a **log-Mel spectrogram**: short
overlapping windows (25 ms, every 10 ms) are converted to frequency content, grouped into
80–128 bands spaced like human hearing (the Mel scale), and log-scaled. The result is an
image: time × frequency. 30 s of audio becomes a 3000 × 128 "picture".

### Whisper = encoder–decoder transformer

1. The **encoder** reads the whole 30 s spectrogram at once and produces a sequence of
   vectors describing it. Whisper always pads to 30 s, so encoding a 2 s line costs as
   much as a 30 s one. That's the fixed cost per line.
2. The **decoder** writes text one *token* at a time. Each step looks at the encoder output
   (cross-attention) and the tokens so far, and outputs a probability for every token in
   the vocabulary (~51k). We take the most likely one (**greedy**, temperature 0) and
   repeat until the end-of-text token.
3. **Special tokens** steer it: `<|ko|>` (language), `<|transcribe|>` vs
   `<|translate|>`, `<|notimestamps|>`. Leaving the language out makes Whisper predict it
   first, which is how auto-detect works.

**Confidence.** Each chosen token has a log-probability. The mean log-probability of a line,
turned back into a probability with `exp`, is a usable "how sure was it" score (see
[Language detection and confidence](07-language-detection-and-confidence.md)).

**Hallucinations.** Trained on subtitled internet video, Whisper, given silence or music,
often writes what subtitles say there: "Thank you for watching.", "[Music]". These are
filtered out.

### Why variants differ in speed

- **Large v3** has 32 decoder layers; **Turbo** cut that to 4, so decoding is ~8× cheaper at
  similar accuracy. The encoder (the 30 s pass) is now the big cost.
- **`large-v3-v20240930_turbo_632MB`** (Argmax) compresses weights and uses an encoder that
  handles shorter audio efficiently. Measured on an M2: **~0.6 s per line vs 1.0–1.2 s**
  for plain Turbo. It's the recommended model.
- **Small** is ~0.35 s but weaker with accents and noise.

### CoreML and the Neural Engine

WhisperKit converts Whisper to CoreML, Apple's model format, which can run on the ANE (a
chip made for matrix math at low power). The first load compiles the model for your exact
chip, which can take minutes; macOS caches the result.

### Streaming recognizers (Apple Speech)

Apple's `SpeechAnalyzer` (macOS 26) is **streaming**: you keep feeding audio and it keeps
reporting. *Volatile* results are its current best guess and can change; a *final*
result for a phrase doesn't change. It does its own endpointing and reports a confidence
per word.

## How Subtitler does it

`AppState.chooseSpeechEngine` picks:

- **Apple Speech** if selected, on macOS 26+, and the spoken language is one it supports
  (EN, KO, JA, ZH, FR, DE, ES, IT, PT). On-device assets are installed with
  `AssetInventory` the first time.
- **Whisper** otherwise (every language, Auto-detect). If Apple Speech was selected but
  can't be used, the best installed Whisper takes over and the panel says why.
- With Auto-detect and Apple Speech (`appleAutoHandover`), it starts on Whisper and hands
  over to Apple once the language is known.

**Whisper (`Transcriber`, an actor around WhisperKit):**
- loads a downloaded folder offline, then **warms up** with 1 s of near-silence so the
  first real line doesn't pay for GPU/ANE setup;
- temperature 0, no timestamps, blank suppression, no-speech threshold 0.6, language token
  prefilled when known;
- calls are serialized through a queue: one decode at a time;
- returns a `Transcript`: text, language, confidence, `looksRepetitive`.

**Apple Speech (`AppleSpeechRecognizer`):** volatile results go to `submitVolatile`, finals
to `submitFinal` with the phrase's end time and word confidences.

**Measured trade-off:** Apple Speech needs no decode, so in quiet audio it's the fastest.
But under film background sound it took 3–4 s to close a sentence, so **Whisper (fast) is
recommended for films**.

## Try it

```sh
Subtitler=app/build/Subtitler.app/Contents/MacOS/Subtitler
say -v Yuna -o /tmp/ko.aiff "어디 갔었어? 밤새 기다렸잖아."
SUBTITLER_TRACE=1 $Subtitler --file /tmp/ko.aiff --source auto --translator off
$Subtitler --file /tmp/ko.aiff --model apple-speech --source ko --translator off
$Subtitler --file /tmp/ko.aiff --model openai_whisper-small --translator off
```

Compare the decode times in the trace across models.

## Code map

- `app/Sources/Subtitler/ASR/Transcriber.swift`: WhisperKit wrapper, `SpeechTranscribing`
- `app/Sources/Subtitler/ASR/AppleSpeechRecognizer.swift`: SpeechAnalyzer
- `AppState.chooseSpeechEngine`, `switchRecognizer`

## Further reading

- Whisper paper, "Robust Speech Recognition via Large-Scale Weak Supervision": https://arxiv.org/abs/2212.04356
- WhisperKit: https://github.com/argmaxinc/WhisperKit
- Apple SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer
