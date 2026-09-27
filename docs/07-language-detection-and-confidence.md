# 7. Language detection and confidence

What you'll learn: how to detect the spoken language robustly, and how to use a model's
own probabilities to hide output it probably got wrong.

## Concepts

**Language ID in Whisper.** With no language token, Whisper's first prediction is the
language. On short audio (< 1 s) it guesses badly, so short lines shouldn't count.

**Voting / debouncing.** One noisy observation shouldn't flip state. Require agreement:
switch only after two results in a row say the same new language.

**Calibrated-ish confidence.** Per-token log-probabilities, averaged and exponentiated,
give a 0–1 score. It isn't perfectly calibrated, but low scores reliably mean "guessing".

**Compression ratio.** A hallucinating model repeats itself ("I'm sorry. I'm sorry.
I'm sorry."). Repetitive text compresses very well, so text length ÷ gzip length > 2.4
flags a loop.

**Limit:** confidence can't catch a *confident* mistake. Apple heard 받았어 as 맞았어 at
0.93.

## How Subtitler does it

### Auto-detect that follows the video

- The first language comes from the **first final**, never a draft.
- Whisper decodes without a hint; every result with ≥ 1.5 s of audio reports a language.
  **Two agreeing results** switch the session (`observeLanguage`). A single foreign line
  or song doesn't.
- While Apple Speech transcribes, Whisper's segmenter keeps running on the same audio via
  the `SampleRouter`, and `detectLanguage` samples the language at most every 3 s.
- On a change, `AppState.followLanguage` restarts Apple Speech in the new language if
  supported, or hands back to Whisper. The session keeps running.

### Hide lines that were hard to hear (`hidesUnclearLines`, on by default)

| Engine | Score | Hidden below |
|---|---|---|
| Whisper | exp(mean token log-prob) | 0.6, or compression ratio > 2.4 |
| Apple Speech | mean per-word `transcriptionConfidence` | 0.5 |

Measured on an M2: clear speech scored 0.92–0.98; speech buried in noise came back as
unrelated words at 0.56. Hidden lines aren't translated; the panel counts them. The
toggle is hidden in subtitle-file mode, where the file's text is shown instead.

**Tried and removed:** passing recent lines as a Whisper prompt (for consistent names).
With WhisperKit it made re-decoded finals come back empty.

## Try it

Mix speech with loud noise and watch the trace's confidence values:

```sh
say -o /tmp/s.aiff "Where have you been all night?"
ffmpeg -y -i /tmp/s.aiff -f lavfi -i "anoisesrc=a=0.3" -filter_complex amix=inputs=2:duration=first /tmp/noisy.wav
SUBTITLER_TRACE=1 app/build/Subtitler.app/Contents/MacOS/Subtitler --file /tmp/noisy.wav --translator off
```

## Code map

- `SubtitlePipeline.swift`: `observeLanguage`, `checkLanguage`, `minWhisperConfidence`, `minAppleConfidence`
- `ASR/Transcriber.swift`: `Transcript.confidence`, `looksRepetitive`, `detectLanguage`
- `AppState.swift`: `followLanguage`, `SampleRouter`
