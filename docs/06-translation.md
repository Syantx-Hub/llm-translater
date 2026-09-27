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

## On-device LLM translation (Gemma 4)

MADLAD only takes the text. A chat LLM can also be told how subtitles should sound, which
names to keep, and what came before, like the cloud LLMs ([Cloud translation](14-cloud-translation.md)).
Models › On-device AI translation offers Google's Gemma 4 (Apache 2.0) as 4-bit GGUFs from
`ggml-org`, run by the same llama.cpp: E2B (2.8 GB), E4B (4.6 GB), 12B (7.2 GB),
26B-A4B MoE (14.6 GB) and 31B (18 GB). `LocalLLMTranslator` is a `BatchTranslating`
engine, so Subtitle file mode and Save Translated Copy batch it with context exactly
like a cloud engine.

**Built for small models.** The larger Gemmas need more memory than most Macs have, so
the engine is tuned for E2B on an 8 GB Mac. A 2B model follows short, concrete prompts
and drifts on long ones; each rule below fixed something seen in testing:

| Technique | Why |
|---|---|
| A GBNF **grammar** forces exactly one `N. …` line per input | Small models merge, split and skip lines. With the grammar a batch can't come back misnumbered. |
| The grammar only allows the target's **script**, Latin and punctuation | E2B slipped Bengali letters into Burmese names ("ဒ্যামေ့ဂျ်"). Now it can't, and picks the nearest Burmese spelling instead. |
| **8-line batches**, a four-rule system prompt, and a **worked example** in 14 languages (my, ko, ja, zh, th, vi, id, es, fr, de, pt, it, ru, hi) | The cloud prompt's 25 lines and eight rules are too much for a 2B model to track. The example shows the register a subtitle wants. |
| **Names transliterated once** per film ("Frank → ဖရန့်", the grammar fixing each name) and given as a fixed list, filtered to the names each batch uses | Without it, each batch spelled a name its own way. |
| Earlier lines come **with the translations already chosen** | Register and wording carry over between batches. |
| Each line is **checked** (target script, not copied, no third script, not runaway) and a failing line is translated again on its own | A cheap second chance for the odd bad line. |
| Greedy decoding that checks only the top token against the grammar, and the whole vocabulary only when that token is rejected | Filtering all 262k tokens at every step made a batch half again as slow. |
| The prompt's fixed start stays in the **KV cache** (`swa_full`, longest common prefix) | The system prompt and example aren't decoded again for every batch. |

Thinking is off (no `<|think|>` in the system turn); Gemma 4's turns are
`<|turn>role\n…<turn|>`, written by `LocalLLMPrompt.gemma` because llama.cpp's built-in
templates predate them.

**Measured** on an M2 with 8 GB, 51 cues of *Spider-Man: Brand New Day*, English →
Burmese, against a cloud LLM's translation as the reference:

| Engine | Time | What stood out |
|---|---|---|
| MADLAD-400 3B Q4 | 28.5 s | Literary register (သည်, ၏), plural "ခင်ဗျားတို့" for one person, names left in English, "The hell, Frank?" → "ပြင်သစ်?" (France) |
| Gemma 4 E2B Q4 | 34.6 s | Spoken register, names in Burmese and consistent, fewer made-up words. Still misreads some idioms ("you said it, not me" reversed), and uses ငါ/မင်း for everyone |
| Gemma 4 E2B, Korean / French | 26 / 27 s | Natural 반말, and French ("Non, mec…") |

**What it can't do yet: pronouns between characters.** Subtitle files don't say who is
speaking, so a translator has to work out from the dialogue that Peter talks to Frank
politely (ကျနော်/ခင်ဗျား) while Frank says ငါ/မင်း. The cloud LLMs do this in their cast
sheet. E2B doesn't, even with the film's background. The viewer's character notes are
the reliable fix for a small model; the larger Gemmas are the other.

## Film background (optional)

Who the characters are (a mother and her son, a boss and his staff) decides pronouns
and politeness in many languages. With **"Look up the film's cast online"** turned on
(off by default), `FilmBackgroundLookup` searches by the title and year from the file
name (`FilmQuery`):

- **Wikipedia** (no key): `Title (2019 film)`, `Title (film)`, `Title`, or for series
  `Title (TV series)`, and failing those a search whose top hit has the same title apart
  from punctuation (file names can't hold ":"). A disambiguation page, or a lead that
  doesn't describe a film (or mention the year), means nothing is used. It reads the
  lead's first two sentences and the **Cast** section only, one sentence per character:
  the rest of an entry often runs into the story, and the Plot section is never
  requested. For targets in their own script it also asks that language's Wikipedia
  (langlinks) how it writes the names: `스파이더맨`, `퍼니셔`. Redirects are skipped, and
  the title may be a translation rather than a sound-alike (Burmese Wikipedia calls
  Spider-Man ပင့်ကူလူသား).
- **TMDB** (only with the viewer's own key): search, then credits (movie, episode, or a
  series' aggregate cast); used only when exactly one result matches the title (and
  year). Adds characters Wikipedia didn't list.

The result is cached per title and language, and shown as editable text next to the
character notes ("Background from Wikipedia: …"). A lookup that fails or finds nothing
never stops a translation: it goes ahead without it.

How each engine uses it:
- **Cloud LLM:** in the cast-sheet request, as trusted facts about who everyone is. The
  model still decides from the dialogue how each pair talks, under the same spoiler-free
  rules.
- **Gemma:** not asked to reason about it. Character names the dialogue uses join the
  names list, spelled as that language's Wikipedia writes them where it has them, and up
  to ten `- Name: who they are` lines (the most mentioned characters) go in each batch
  that mentions them, under "Who's who (pick pronouns and politeness to fit)".
- **MADLAD** takes no context, and the lookup doesn't run for it.

## Try it

```sh
Subtitler=app/build/Subtitler.app/Contents/MacOS/Subtitler
printf '1\n00:00:01,000 --> 00:00:03,000\nWhere have you been all night?\n' > /tmp/t.en.srt
time $Subtitler --translate-subtitles /tmp/t.en.srt --target my && cat /tmp/t.my.srt
```

Try `--target ko`, `ja`, `zh`. For quality comparison with NLLB, see `python/eval.py`.

With a Gemma model downloaded, the same file through the on-device LLM, looking up the
film's cast (the flag does the lookup whatever the app's setting):

```sh
SUBTITLER_TRACE=1 $Subtitler --translate-subtitles "Movie (2019).en.srt" --target my \
  --translator gemma-4-e2b-q4_0 --look-up-background
```

The trace prints the cast sheet (names and who's who) and each batch's time.

## Code map

- `app/Sources/Subtitler/Translation/LlamaTranslator.swift`: llama.cpp loop, shared `Llama` helpers
- `app/Sources/Subtitler/Translation/LocalLLMTranslator.swift`: Gemma engine; `LocalLLMPrompt` (prompts, grammars, checks, examples)
- `app/Sources/Subtitler/Subtitles/FilmBackground.swift`: film background lookup (Wikipedia, TMDB, cache)
- `app/Sources/Subtitler/UI/FilmBackgroundViews.swift`: the Models section and the editable background
- `app/Sources/Subtitler/Translation/Translator.swift`: protocol, factory, passthrough, sidecar engine enum
- `app/Sources/Subtitler/Translation/SidecarTranslator.swift`, `python/translate_server.py`
- `app/Sources/Subtitler/Translation/Languages.swift`
- Tests: `LlamaTranslatorTests`, `LocalLLMTranslatorTests`, `FilmBackgroundTests`, sentence splitting in `SubtitlePipelineTests`

## Further reading

- MADLAD-400 paper: https://arxiv.org/abs/2309.04662
- T5 paper: https://arxiv.org/abs/1910.10683
- llama.cpp: https://github.com/ggml-org/llama.cpp
- GBNF grammars: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md
- Gemma 4: https://huggingface.co/google/gemma-4-E2B-it
- Quantization types explained: https://github.com/ggml-org/llama.cpp/blob/master/tools/quantize/README.md
