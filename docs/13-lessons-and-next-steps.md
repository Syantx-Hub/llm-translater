# 13. Lessons and next steps

## Lessons (AI engineering)

1. **Measure before optimizing.** Translation looked like the bottleneck; the trace showed
   the Whisper decode was. Switching to the `_turbo_632MB` variant halved it.
2. **The model is rarely the whole answer.** The biggest latency win was scheduling
   (reusing the pause draft), not a faster model.
3. **Test on realistic data.** Clean TTS worked with an energy VAD; film audio didn't.
   Silero fixed it. Apple Speech was fastest in quiet audio and slowest in noise.
4. **Change the problem.** Live translation can't be on time. Aligning to an existing
   subtitle file can, and it needs no model beyond the recognizer you already have.
5. **Use the model's own uncertainty.** Log-probabilities give a cheap "was this heard
   right?" filter.
6. **UX shapes the pipeline.** Word order (SOV languages) made "translate half a sentence"
   a bad experience, so translate mode shows finished sentences only.
7. **Some good ideas fail in practice.** Prompting Whisper with previous lines made
   finals empty; it was removed.
8. **Put models behind protocols** so the logic around them is testable in milliseconds.

## Known limitations

- **Drafts re-decode the whole utterance** each time. A streaming policy (LocalAgreement)
  would stabilize drafts and save work.
- **Offline translation has no context.** MADLAD translates sentence by sentence; names
  and register aren't consistent. The optional cloud engine fixes this for files
  ([Cloud translation](14-cloud-translation.md)).
- **Sync needs same-language subtitles.** A file in another language would need
  timing-only alignment.
- **Confident mistakes** pass the unclear-line filter.
- **Burmese line breaking** relies on CoreText; syllable-aware breaking isn't verified.
- **No automated session lifecycle test** (capture would need a fake).
- **Permission checks use TCC SPI**; if Apple removes it, status shows as unknown.
- **Distribution**: ad-hoc signed; shipping needs Developer ID, notarization, an updater.

## Ideas to explore next

- A larger local translator, or a small LLM post-editing MADLAD output with context.
- Timing-only subtitle alignment for files in another language.
- Speaker labels (diarization) so two people's lines don't merge.
- LocalAgreement streaming for steadier live words in transcribe mode.
