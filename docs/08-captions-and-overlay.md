# 8. Captions and the overlay

What you'll learn: how to draw on top of everything on macOS without stealing clicks, and
why the preview and the real overlay share one view.

## Concepts

**A floating, click-through window.** An `NSPanel` at `.screenSaver` level sits above
full-screen video; `ignoresMouseEvents` passes clicks through; `.canJoinAllSpaces` +
`.fullScreenAuxiliary` make it appear on every Space, including full-screen apps.

**One source of truth for rendering.** If the preview is drawn by different code from the
overlay, they drift apart. Render both with one view and scale it.

## How Subtitler does it

- `OverlayPanel`: borderless, non-activating, never key or main.
- `OverlayController` sizes it to the screen with the mouse pointer (minus the notch) and
  re-picks the screen when displays, Spaces or the front app change. The panel covers
  the whole screen, so moving captions only re-lays out SwiftUI.
- `CaptionSlot.slots(...)` decides what's on screen: `lineCount` boxes (default 1). The
  bottom box has a fixed identity: live words and then the finished line appear *in the
  same box*, in the same style, so nothing jumps.
- `CaptionLayer` is used by both the overlay and the Captions window preview; the preview
  passes `scale = previewWidth / screenWidth`.
- `CaptionStyle` persists every setting (`caption.*`): font, weight, size, spacing,
  colours, edge (shadow or outline), background, position, offset, width, line count,
  show original (off by default), clear-after.
- Font "Automatic" = Noto Sans Myanmar for Burmese (shapes stacked consonants correctly),
  system font otherwise. Both ship with macOS.
- `SampleCaptions` has lines in every language so the preview shows real scripts.
- The same `CaptionLayer` also powers the small preview in the panel and the tour
  (`CaptionPreview` in `UI/Explain.swift`): choosing a mode replays a few seconds of what
  that mode shows (words arriving for Transcribe, whole sentences for Translate, lines on a
  running clock for Subtitle file), in your caption style.

## Try it

```sh
app/build/Subtitler.app/Contents/MacOS/Subtitler --snapshot /tmp/ui && open /tmp/ui
```

Renders every window and the overlay, light and dark, offscreen.

## Code map

- `app/Sources/Subtitler/Overlay/`: `OverlayController`, `SubtitleOverlayView` (`CaptionSlot`, `CaptionLayer`), `CaptionStyle`, `SampleCaptions`
- `app/Sources/Subtitler/UI/CaptionsView.swift`: settings + live preview
- Tests: `CaptionStyleTests`, `CaptionSlot` tests
