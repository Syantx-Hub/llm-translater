# 14. Cloud translation (optional)

What you'll learn: when a general LLM beats a dedicated translation model, how to prompt
and batch an LLM for subtitles, how to call seven different provider APIs through one
interface, and how to handle a user's API key without ever exposing it.

## Concepts

### Why an LLM can translate better than MADLAD

MADLAD ([Translation](06-translation.md)) sees one sentence and a `<2my>` tag. It can't
be told anything. That causes three visible problems:

| Problem | Why MADLAD can't fix it | What an LLM gets |
|---|---|---|
| Names get translated ("Jin-woo" becomes a word) | No instructions | "Transliterate names; never translate their meaning" + a list of the film's names |
| Formal speech between friends | No idea who is talking to whom | The earlier lines, so it can infer the relationship and choose the register |
| A pause splits one sentence | Each half is a "sentence" | Split cues are joined first (`SubtitleSentences`), and neighbours are visible anyway |

This is **prompt engineering plus context engineering**: the rules (system prompt), the
situation (earlier lines), and the facts (names glossary) are all input the model uses.

### Batching and structured output

Sending one request per line would be slow and use up free quotas: a film has ~1,000
lines. So lines go **25 at a time**, numbered:

```
Names in this film (keep them as names): Jin-woo, Mina
Earlier lines, for context only (don't translate them):
> We're late.
Translate these 3 lines. Reply with exactly 3 lines, each starting with its number:
1. Jin-woo, wait!
2. Where are you going?
3. Home.
```

Models sometimes merge, drop or re-number lines. `LLMPrompt.parseNumbered` accepts the
reply only if every number 1…n appears exactly once. Otherwise the batch is **split in
half and retried**, down to single lines, so a bad reply costs a few extra requests, not
wrong subtitles on the wrong lines.

### One interface, three API styles

| Style | Providers | Endpoint | Auth header |
|---|---|---|---|
| OpenAI chat completions | OpenAI, Mistral, DeepSeek, Groq, OpenRouter, Ollama, LM Studio | `POST {base}/chat/completions` | `Authorization: Bearer` |
| Anthropic Messages | Anthropic | `POST /v1/messages` | `x-api-key` + `anthropic-version: 2023-06-01` |
| Gemini generateContent | Google Gemini | `POST /v1beta/models/{model}:generateContent` | `x-goog-api-key` |

`CloudAdapter` builds each request and reads each reply as pure functions, so tests check
exactly what would be sent. Provider quirks (checked against each provider's docs on
2026-09-26):

- Newer OpenAI models take `max_completion_tokens` and only accept `temperature` when
  reasoning is off (`reasoning_effort: "none"`).
- Current Claude models reject a non-default `temperature`, so none is sent.
- DeepSeek thinks by default; `thinking: {type: "disabled"}` makes it fast. It also
  sends blank lines while a request is queued, so replies are trimmed before parsing.
- Gemini's `maxOutputTokens` includes hidden thinking; thought parts are skipped.
- OpenRouter can return an error inside a 200 reply (`finish_reason: "error"`).

## How Subtitler uses it

- **Subtitle file mode:** when the session syncs, the whole file is translated in
  batches, starting at the current position (a seek moves the work there). After every
  batch the translations are saved next to the file as `Movie.<lang>.srt`, so watching
  again sends nothing.
- **Save Translated Copy:** the same batches, with progress and requests shown.
- **Live Translate:** works, one request per sentence with the previous lines as
  context, but it adds network lag and uses many requests, so the UI recommends offline
  MADLAD for live.
- **Resumable:** if a daily limit runs out, what's done is saved. The next run reads the
  partial `Movie.<lang>.srt` (`SyncTranslations.existingTranslations`) and translates only
  the rest.

## Security design, and why each rule exists

| Rule | Why |
|---|---|
| Keys only in the Keychain: generic password, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable | Encrypted at rest, unreadable while the Mac is locked, never copied to iCloud or other devices. UserDefaults, `.env` and plist files are plain text anyone (or any backup) can read. |
| Read the key per request, never kept in `@Published` or long-lived properties | Less time in memory, and nothing SwiftUI might snapshot, persist or show. The typed key lives in a non-published draft that's cleared on save or when the window closes. |
| Show only `••••1234`, with Replace and Remove | Shoulder-surfing and screenshots. The last four characters are enough to tell keys apart. Remove deletes the Keychain item. |
| Key in the auth header, never the URL (Gemini too: `x-goog-api-key`) | URLs end up in logs, proxies, crash reports and error messages. |
| HTTPS to the official host; custom endpoints need https, except `http://localhost` / `127.0.0.1` | Plain http sends the key readable on the network. Local servers never leave the Mac. |
| Ephemeral `URLSession`: no cache, cookies or credential storage | Nothing about requests is written to disk. |
| Refuse redirects to another host or scheme | URLSession carries headers across redirects, so a redirect could hand the key to another server. (None of the providers' API hosts redirect; checked with probes.) |
| Redact key-shaped strings from provider errors (`sk-…`, `AIza…`, `gsk_…`, `Bearer …`, long tokens) | Providers echo parts of rejected keys ("Incorrect API key provided: sk-…"). |
| Never logged: `SUBTITLER_TRACE` prints timings only; snapshots use an in-memory store | Logs and screenshots get shared. |
| Timeouts; backoff on 429 using `retry-after`; stop on a used-up quota | Don't hang, and don't hammer a provider (or burn money) retrying something that won't succeed today. |

## Usage and cost (shown in the app)

Everything here is **approximate**. Limits and prices change; the app always links the
provider's own pricing and rate-limit pages.

| Provider | Free tier (as documented on 2026-09-26) | Notes |
|---|---|---|
| OpenRouter | Free models (`:free`): ~20 requests/min, 50/day (1,000/day after buying $10 of credits) | Free-model providers may train on your text |
| Groq | ~30 requests/min, 1,000/day per model | Doesn't keep request data by default |
| Google Gemini | Every model, limits shown in AI Studio | Free tier: text may be used to improve Google's products; not available in every country (Myanmar isn't listed); EEA/CH/UK paid only |
| OpenAI | Free tier in some countries, limits not published | API data not used for training unless you opt in |
| Mistral | Free plan with monthly credits | Check the privacy setting to opt out |
| Anthropic, DeepSeek | None (paid only) | DeepSeek stores data in China and may train on it |
| Custom (Ollama, LM Studio) | Free, on your Mac | Nothing leaves the Mac |

What the app shows, and where:

- **Provider card** (Models › Cloud): where to get a key, whether there's a free tier, the
  free limits (approximate, with a link), and "Subtitle text is sent to <provider>. Audio
  never leaves the Mac. The provider may charge you on paid plans." Details sit behind
  "Learn more".
- **Before a whole-file run:** "≈ 12 requests to Groq, about 1–2 min · about 1% of today's
  free requests". Nothing is sent until Start.
- **While running:** progress; on 429 "Waiting for <provider>'s rate limit… 12 s" instead
  of an error; if the day's quota runs out: "Daily limit reached. Translated N of M lines;
  the rest will continue next time (or switch to offline MADLAD)."
- **Cached:** "Cached: watching again sends nothing" when the translated file exists.

The estimate (`CloudEstimate`): sentences still to translate ÷ 25 = requests. Time =
requests × max(60 / requests-per-minute, 4 s) to requests × max(1.2 × that, 10 s),
because requests go one after another and each batch reply takes a few seconds.

## Try it

- Free and local: install Ollama, run a model (`ollama run gemma3`), then choose Models ›
  Cloud › Custom › Ollama, type the model name, Test.
- Free online: create an OpenRouter or Groq key, paste it, Test, then Use for Translation.

## Code map

- `Translation/Cloud/CloudProvider.swift`: providers, models, free tiers, links
- `Translation/Cloud/CloudAdapter.swift`: request building and reply parsing per style
- `Translation/Cloud/CloudTranslator.swift`: the translator, batching, pacing, `CloudConfig`, `CloudActivity`
- `Translation/Cloud/CloudHTTP.swift`: ephemeral session, redirect guard, retries, redaction
- `Translation/Cloud/KeychainStore.swift`: Keychain storage, masked hint
- `Translation/Cloud/LLMPrompt.swift`: system prompt, batch prompt, numbered parsing, names glossary
- `Subtitles/SentenceTranslation.swift`: resumable batch runs, `CloudEstimate`
- `UI/CloudSection.swift`, `UI/TranslationEngineViews.swift`: the UI
- Tests: `CloudTests.swift` (adapters, key only in headers, redirects, http rules, redaction, Keychain, parsing, estimate, 429 countdown, quota partial save and resume, factory)

## Further reading

- OpenAI Chat Completions: https://developers.openai.com/api/docs
- Anthropic Messages: https://platform.claude.com/docs/en/api/messages
- Gemini API: https://ai.google.dev/api/generate-content
- OWASP, secrets management: https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html
