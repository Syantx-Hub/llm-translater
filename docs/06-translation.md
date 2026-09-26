# 6. Translation

What you'll learn: how neural machine translation works, tokens, quantization, how
llama.cpp runs a model on the GPU, decoding strategies and their failure modes.

## Concepts

### Encoder–decoder translation

MADLAD-400 is a **T5** model: the same encoder–decoder shape as Whisper, with text in
instead of audio.

1. **Tokenize** the input into subword pieces (SentencePiece). "unbelievable" might become
   `▁un` `believ` `able`. Rare scripts get more, shorter pieces, which is why Burmese
   output uses 2–3× as many tokens as the English input.
2. The **encoder** reads all input tokens at once (one pass) → vectors.
3. The **decoder** writes the output token by token, attending to the encoder vectors and
   its own previous tokens.

MADLAD is **multilingual**: one model for 400+ languages. The target language is chosen by
a prefix token, `<2my>` for Burmese, `<2ko>` for Korean. The source language doesn't need
to be given; the encoder recognizes it.

Decoder-only LLMs (GPT, Llama) can translate too, but at the 3B size, a dedicated
translation model is better for low-resource languages like Burmese, and the
encoder–decoder shape makes one input pass cheap.

### Decoding

- **Greedy**: always take the most likely token. Deterministic and fast, good for
  translation.
- **Failure mode: loops.** Small models sometimes get stuck repeating a phrase.
- **Repetition penalty**: lower the score of tokens seen recently.
- **Length cap / loop guard**: stop if the output is implausibly long or repeating.

### Quantization and GGUF

A 3B model at 16-bit is ~6 GB. **Quantization** stores weights in fewer bits:
- **Q8_0**: 8 bits, ~3.1 GB, almost lossless.
- **Q4_K_M**: ~4.5 bits (blocks of weights share a scale), ~1.9 GB, slightly worse wording.

Generation speed on a laptop is limited by **memory bandwidth** (every token reads every
weight), so smaller weights are also *faster*. GGUF is llama.cpp's single-file format for
quantized weights, tokenizer and metadata.

### llama.cpp

A C/C++ inference engine with a Metal (GPU) backend. The loop you write:
`llama_tokenize` → `llama_encode` (encoder) → repeatedly `llama_decode` + sample →
`llama_token_to_piece`. The **KV cache** stores the attention keys/values of previous
tokens so each new token doesn't recompute them.

## How Subtitler does it

`LlamaTranslator` (an actor) per sentence:

1. Clear the KV memory and reset the sampler.
2. Tokenize `<2{target}> {text}` (max 480 tokens) and `llama_encode` it in one batch
   (`n_batch = n_ubatch = 512`, because the encoder must see the whole input at once).
3. Decode from the decoder start token with **repetition penalty (last 64 tokens, ×1.15)
   then greedy**.
4. Stop at end of generation, at min(256, 4 × input + 16) tokens, or when the last 8 tokens
   repeat the 8 before them.
5. Detokenize.

All layers on the GPU. `start()` does one throwaway translation so Metal kernels compile
before the first real line. **Speed on an M2: ~26 tokens/s (~39 ms/token), ~0.5 s for a
typical sentence.**

Around it, `SubtitlePipeline.translate`:
- splits text into sentences and translates one at a time (small models drop clauses or
  loop on long run-ons, and short inputs are faster);
- caches per sentence;
- skips translation when source = target;
- on failure shows the original with an error rather than nothing.

`Translator` is a protocol, so `TranslatorFactory` can return MADLAD, the Python
**sidecar** (NLLB-200 for comparison; `--dev` builds only, JSON lines over stdin/stdout),
or `PassthroughTranslator` (`off`).

**Why word order matters for UX:** Burmese is subject-object-verb. "I didn't eat the
rice *yesterday*" can't be translated until the verb arrives, so translate mode waits for
the finished sentence ([Live pipeline](05-live-pipeline-and-latency.md)).

**Languages:** `Languages.swift` lists 45; codes are ISO 639-1, which both Whisper and
MADLAD's `<2xx>` tags use.

## Try it

```sh
Subtitler=app/build/Subtitler.app/Contents/MacOS/Subtitler
printf '1\n00:00:01,000 --> 00:00:03,000\nWhere have you been all night?\n' > /tmp/t.en.srt
time $Subtitler --translate-subtitles /tmp/t.en.srt --target my && cat /tmp/t.my.srt
```

Try `--target ko`, `ja`, `zh`. For quality comparison with NLLB, see `python/eval.py`.

## Code map

- `app/Sources/Subtitler/Translation/LlamaTranslator.swift`: llama.cpp loop
- `app/Sources/Subtitler/Translation/Translator.swift`: protocol, factory, passthrough, sidecar engine enum
- `app/Sources/Subtitler/Translation/SidecarTranslator.swift`, `python/translate_server.py`
- `app/Sources/Subtitler/Translation/Languages.swift`
- Tests: `LlamaTranslatorTests`, sentence splitting in `SubtitlePipelineTests`

## Further reading

- MADLAD-400 paper: https://arxiv.org/abs/2309.04662
- T5 paper: https://arxiv.org/abs/1910.10683
- llama.cpp: https://github.com/ggml-org/llama.cpp
- Quantization types explained: https://github.com/ggml-org/llama.cpp/blob/master/tools/quantize/README.md
