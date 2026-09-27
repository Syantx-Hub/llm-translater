# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI + AppKit menu bar app; not one of web/ios/android/adaptive)

## Users

- Primary: Burmese-speaking viewers watching Korean, Japanese, Chinese and English films and TV on a Mac (streaming sites, video players), who want subtitles in Burmese (or another language). Not technical; they won't read docs, so every feature must explain itself in the app.
- Also: the author, who uses the project to learn AI engineering. In-app explanations should be plain for viewers, and the docs (docs/) go deeper.
- The app will be shared with other people (friends, public).

## Product Purpose

Subtitler listens to whatever the Mac plays and shows subtitles in a floating, click-through overlay, translated or as spoken, fully on device by default. Success: someone opens it, understands which of the three ways to use it fits what they're watching, and sees good, on-time subtitles within minutes.

## Positioning

- Offline by default: speech recognition (Whisper / Apple Speech) and translation (MADLAD-400) run on the Mac; audio never leaves it.
- Subtitle file mode: instead of translating live (always ~1.5 s late), it finds its place in the film's own subtitle file by listening, and shows the file's lines translated, exactly on time, even on streaming services.
- Optional cloud LLM translation with the user's own key, for better, context-aware wording.

## Operating Context

- Used while a video plays full screen; the control panel lives in the menu bar and a main window. The user starts a session, then mostly looks at the video, not the app.
- Three modes, none privileged; onboarding explains all three and lets the user choose:
  - **Translate**: live translation of whatever is playing, finished sentences only.
  - **Transcribe**: the original words as they're spoken.
  - **Subtitle file**: pick or find the film's subtitles (OpenSubtitles), sync by listening, show translated on the file's timing. Also "Save Translated Copy" for any video player.
- Models are downloaded inside the app (speech, translation), like Wispr Flow / Handy.
- Needs the macOS System Audio Recording permission.

## Capabilities and Constraints

- macOS 14+, Apple Silicon (all M-series), 8 GB RAM floor.
- Built with Swift Package Manager and Command Line Tools only: no Xcode, no SwiftUI `@State` macro (views use `@StateObject` / `ObservableObject`).
- Burmese is the primary subtitle language; 45 languages supported. Burmese script needs Noto Sans Myanmar and room for stacked glyphs.
- Cloud providers: OpenAI, Anthropic, Gemini, Mistral, DeepSeek, Groq, OpenRouter, Custom OpenAI-compatible (Ollama, LM Studio). Keys only in the Keychain, shown masked (••••1234). Usage and privacy notes must be honest, approximate and linked to provider pages.
- Offline MADLAD stays the default; nothing is sent anywhere unless the user turns a cloud engine on.

## Brand Commitments

- Name: Subtitler. Bundle id com.syantxhub.subtitler (Syantx-Hub).
- Voice: plain, short, calm; explain what a feature is for in one line, details behind "Learn more".

## Evidence on Hand

- No testimonials, users or benchmarks to show; measured numbers exist only in docs/ (latency, sync accuracy). Don't invent claims.

## Product Principles

1. Explain by doing: each feature says what it's for, in the place it's used.
2. Privacy is the default and always visible: what stays on the Mac, and exactly what leaves when the user opts in.
3. The video comes first: set up once, then get out of the way.
4. Honest about limits: lag, quality, costs and quotas are stated plainly, never hidden or exaggerated.

## Accessibility & Inclusion

- Caption readability (size, outline, background) is user-controlled; UI text follows macOS Dynamic Type sizes where SwiftUI allows.
