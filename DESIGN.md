---
name: Subtitler
description: A first-party Mac utility where every control says what it's for, right where it sits.
colors:
  accent: "AccentColor"
  link: "LinkText"
  label: "rgba(0, 0, 0, 0.85)"
  secondary-label: "rgba(0, 0, 0, 0.5)"
  control-background: "#ffffff"
  window-background: "#ececec"
  hairline: "rgba(0, 0, 0, 0.08)"
  caution-orange: "#ff9500"
  done-green: "#28cd41"
  failure-red: "#ff3b30"
  scene-top: "#292929"
  scene-bottom: "#121212"
  scene-glow: "rgba(92, 79, 61, 0.55)"
  caption-text: "#ffffff"
  caption-box: "rgba(0, 0, 0, 0.62)"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "26pt"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "17pt"
    fontWeight: 600
  title:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "15pt"
    fontWeight: 600
  heading:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
  body-emphasis:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 500
  callout:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 400
  footnote:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 400
  micro:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 600
    fontFeature: "tnum"
  caption-overlay:
    fontFamily: "Noto Sans Myanmar, SF Pro, system-ui"
    fontSize: "34pt"
    fontWeight: 500
    lineHeight: 1.35
rounded:
  row: "8px"
  inset: "10px"
  card: "12px"
  capsule: "999px"
spacing:
  tight: "2px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  row: "10px"
  group: "12px"
  panel: "14px"
  card: "16px"
  step: "18px"
  window: "24px"
components:
  button-prominent:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
  button-bordered:
    backgroundColor: "{colors.control-background}"
    textColor: "{colors.label}"
  button-link:
    textColor: "{colors.link}"
    typography: "{typography.footnote}"
  mode-row:
    rounded: "{rounded.row}"
    padding: "8px 10px"
  mode-row-selected:
    backgroundColor: "color-mix(in srgb, AccentColor 10%, transparent)"
    rounded: "{rounded.row}"
    padding: "8px 10px"
  field-row-label:
    textColor: "{colors.label}"
    typography: "{typography.body}"
    width: "118px"
  help-note:
    textColor: "{colors.secondary-label}"
    typography: "{typography.footnote}"
  notice-row:
    textColor: "{colors.secondary-label}"
    typography: "{typography.footnote}"
  notice-row-caution:
    textColor: "{colors.label}"
    typography: "{typography.footnote}"
  model-card:
    backgroundColor: "{colors.control-background}"
    rounded: "{rounded.card}"
    padding: "16px"
  model-card-compact:
    backgroundColor: "{colors.control-background}"
    rounded: "{rounded.card}"
    padding: "12px"
  badge:
    textColor: "{colors.accent}"
    backgroundColor: "color-mix(in srgb, AccentColor 12%, transparent)"
    typography: "{typography.micro}"
    rounded: "{rounded.capsule}"
    padding: "2px 6px"
  step-number:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    typography: "{typography.micro}"
    rounded: "{rounded.capsule}"
    size: "16px"
  caption-preview:
    backgroundColor: "{colors.scene-bottom}"
    rounded: "{rounded.row}"
    height: "118px"
  caption-box:
    backgroundColor: "{colors.caption-box}"
    textColor: "{colors.caption-text}"
    typography: "{typography.caption-overlay}"
    rounded: "{rounded.inset}"
  panel:
    width: "360px"
    padding: "14px"
---

# Design System: Subtitler

## Overview

**Creative North Star: "The Annotated Control Panel"**

Subtitler looks like something Apple could have shipped: SwiftUI's own controls, the system accent, SF Pro through text styles, SF Symbols, `controlBackgroundColor` cards on the window background, in light and dark. What sets it apart is not a visual flourish but a habit. Every control carries a one-line secondary-grey footnote saying what it does. Longer detail sits behind a small "Learn more" link, and every status is a sentence with a symbol. The whole interface explains itself in the place the user already is.

The system has one deliberately non-system element: the **caption preview**. It is a small letterboxed dark frame (a dim film scene) with the real `CaptionLayer` drawn in it at true screen proportion. It plays a few seconds of what the chosen mode does and replays whenever the mode changes. This is the only place the app draws its own colours. Everything else inherits the Mac.

Density is compact, like a utility. The 360pt menu bar panel stacks header, preview, the three mode rows, the mode's settings and a "How this works" disclosure on 10–14pt rhythm. Windows (Welcome, Models, Captions, Find subtitles, Save a translated copy) open to a semibold title plus one secondary sentence, then content.

**Key Characteristics:**
- Native materials only: system semantic colours, the user's accent, SF Pro text styles, SF Symbols.
- A footnote under each control (`HelpNote`), details behind a disclosure (`LearnMore`).
- Status as a sentence with a symbol (`NoticeRow`), toned calm, orange (costs time or money) or green (done).
- One real caption preview, the only non-system surface, replayed on every mode change.
- Light and dark are both first-class; nothing is hard-coded to one appearance except the caption scene, which is always dark.

## Colors

The palette is the Mac's. The app adds colour only through the user's accent, three status hues, and the dark film scene the captions sit on.

The system colour names are normative. The hex values in the frontmatter are light-appearance references for tooling. In code they are always `Color.accentColor`, `.primary`, `.secondary`, `Color(nsColor: .controlBackgroundColor)`, `.orange`, `.green` and `.red`, so dark mode and the user's accent come for free.

### Primary
- **System Accent** (`AccentColor`): the user's own accent (purple in the review captures). It marks selection and progress. It tints the selected mode row (10% fill), its lead symbol and `checkmark.circle.fill`, the selected model card's 1.5pt border, "In use" labels, the "Recommended" badge, the step-number discs, meter pips and the current step dot. It also fills the one prominent button on each surface.

### Secondary
- **System Link** (`LinkText`): `.buttonStyle(.link)` renders in the system link colour, not the accent. That covers "Learn more", "How Translate works", "Type an ID…", "Cloud options…", "Delete" and "Cancel" in download rows. The review captures show it blue beside a purple accent. That is macOS behaviour, and the system keeps it.

### Tertiary (status)
- **Caution Orange** (`.orange`): used for things that cost time, money or capability: the caution `NoticeRow` icon, the "Needs 16 GB" and "Non-commercial" badges, a denied permission, a missing API key, and models still downloading. Caution text stays primary. Only the glyph turns orange.
- **Done Green** (`.green`): something finished or is working. It covers the done `NoticeRow` icon, the running status in the panel header, strength checkmarks on model cards, "Permission granted", and the "Ready" banner in Find subtitles (green at 10% fill).
- **Failure Red** (`.red`): used only for a failed phase in the header, a failed model download and search errors. It is never decorative.

### Neutral
- **Label** (`.primary`): control labels, mode names, caution notice text.
- **Secondary Label** (`.secondary`): every footnote, purpose line, status line, stat row and window subtitle. It is the voice of the explanations, and the most-used colour in the build.
- **Control Background** (`controlBackgroundColor`): the fill of cards: model cards, the cloud setup card, the drop zone and the "You're set up" summary.
- **Hairline** (`.primary` at 8%): the resting border on cards, so they hold their edge on either appearance. The drop zone uses 12% in a dashed stroke.

### Caption scene (the non-system element)
- **Scene Top / Scene Bottom** (`white 0.16` to `white 0.07`): a vertical dim-film gradient behind the preview captions.
- **Scene Glow** (warm `rgb 0.36/0.31/0.24` at 55%): one radial warm glow, off-centre (x 0.7, y 0.35), so the frame reads as a lit scene and not a black box.
- **Caption Text / Caption Box**: the user-controlled `CaptionStyle` defaults (white on black at 62%). The preview always draws the user's current style, never a fixed one.

### Named Rules
**The Borrowed Palette Rule.** Every colour outside the caption scene is a system semantic colour or the accent. Never hard-code a hex for chrome.

**The Glyph-Only Caution Rule.** A caution tints the symbol orange and keeps the sentence in primary text. Orange paragraphs and red chrome are not used.

**The One Prominent Button Rule.** Each surface has at most one `.borderedProminent` button, the next step: Start/Stop in the panel, Continue in the tour, Download on a card, Use for Translation, Start Now. When the page itself holds the prominent action (Allow… on the permission step), the footer's button goes plain.

## Typography

**Display Font:** SF Pro, through SwiftUI text styles only.
**Body Font:** SF Pro (same).
**Caption Font:** Noto Sans Myanmar for Burmese when the caption font is Automatic. Otherwise San Francisco, SF Rounded or New York, as the user picks.

**Character:** the text styles are the system's, and hierarchy comes from weight (semibold titles, medium mode names) and from the primary/secondary split, not from size jumps. Sizes in the frontmatter are macOS defaults for each text style. The code names the style, never the point size.

### Hierarchy
- **Display** (`.largeTitle` semibold): one per window, for the window's own name: "Subtitles for anything you watch", "Models".
- **Headline** (`.title2` semibold): step and window titles: "How will you use Subtitler?", "How subtitles look", "Find subtitles", "Let Subtitler hear your Mac".
- **Title** (`.title3` semibold): section heads inside a window: "Speech recognition", "Cloud translation (optional)". `.title3` monospaced semibold also carries the latency readout ("1.2 s behind").
- **Heading** (`.headline`): the app name in the panel header, model names, search result titles, "What it can do".
- **Body** (`.body`; `.body` medium for mode names): field labels, toggles, file names.
- **Callout** (`.callout`, secondary): window subtitles, model summaries, the tour's step lists, capability titles (semibold).
- **Footnote** (`.caption`, secondary): every `HelpNote`, `NoticeRow`, mode purpose line, stats row and link-style secondary action.
- **Micro** (`.caption2` semibold/bold, tabular): badges, step numbers, the preview's timecode chip, "behind".

### Named Rules
**The Text-Style Rule.** Chrome text uses SwiftUI text styles (`.caption`, `.callout`, `.headline`…), never fixed point sizes, so Dynamic Type sizes carry through.

**The Tabular Numbers Rule.** Every number that changes (latency, timing offset, slider readouts, download percent, key hint, timecode) is `.monospacedDigit()`.

**The Burmese Room Rule.** Captions in Burmese default to Noto Sans Myanmar with line spacing of 0.35 × font size, and the caption box pads vertically by 0.3 × font size, so stacked glyphs never clip.

## Layout

- **Panel:** a fixed 360pt column, padded 14pt, `VStack` spacing 12. The order is fixed: header (app name + status sentence on the left, optional latency readout, Start on the right), caption preview (118pt tall, hidden while running), mode chooser, the mode's settings (spacing 10), the "How <mode> works" disclosure, messages, a divider, then the footer (Captions…, Models…, `?`, spacer, Quit).
- **Label column:** `FieldRow` puts labels in a fixed 118pt column with an 8pt gap, so every popup in the panel starts at the same edge. This is the grouped-form look in a panel too narrow for `Form`. Windows wide enough for it (Captions, Save a translated copy) use `Form` with `.formStyle(.grouped)` instead.
- **Control to footnote:** 2–4pt between a control and its `HelpNote` (4pt under popups, 2pt under toggles and the timing stepper).
- **Windows:** fixed sizes per window (tour 640×680, Find subtitles 560×600, Save copy 520×560). Content is padded 20–24pt (tour 32pt horizontal, 28pt top), the footer bar sits below a divider at 24pt/14pt, and title-to-subtitle spacing is 3–4pt.
- **Rhythm:** 2 / 4 / 6 / 8 / 10 / 12 / 14 / 16 / 18 / 24. The most common gaps are 6 (disclosures, step lists, notices) and 4 (tight groups).
- **Lead glyph column:** list rows with a lead symbol (mode rows, tour capabilities) give it a 24pt column, 10pt from the text.

## Elevation & Depth

The system is flat. Depth comes from native tonal layering: `controlBackgroundColor` cards on the window background, with a hairline border at 8% primary. There is exactly one shadow in the chrome, on the caption preview (`black 18%, radius 6, y 3`), which lifts the film frame off the panel like a small screen. The caption layer's own text edge (shadow or outline) belongs to the captions, not the chrome.

### Shadow Vocabulary
- **Preview lift** (`black 18%, radius 6, y 3`): the caption preview only.
- **Caption shadow edge** (`black 85%, radius 3, y 1`, scaled): the default caption text edge, for readability on bright video.

### Named Rules
**The One Lifted Frame Rule.** Only the caption preview casts a shadow. Cards, rows and banners stay flat and are separated by fill and hairline.

## Shapes

Everything uses continuous (squircle) rounded rectangles, the Mac's own corner.
- **Row** (8pt): mode chooser rows and the tour caption preview frame.
- **Inset** (10pt): the Captions window's preview frame, the "Ready" banner, and the caption box default.
- **Card** (12pt): model cards, the cloud setup card, the drop zone, and the tour's summary card.
- **Capsule**: badges, the preview's timecode chip, meter pips (10×4pt), step-number discs (16pt circle) and step dots (6pt).

Borders are 1pt hairlines at rest and 1.5pt accent when selected. The only dashed stroke is the drop zone (1.5pt, dash 6/4), which turns accent when a file hovers over it.

## Components

### Buttons
- **Shape:** native macOS bordered buttons, no custom styles.
- **Prominent (`.borderedProminent`):** accent fill, white label, one per surface (see The One Prominent Button Rule). Start in the panel header is also `.controlSize(.large)` and the default action (Return).
- **Bordered (default):** secondary actions such as Choose File…, Find Online…, Replace, Test, Captions… and Models…. Titles that open a window or dialog end in an ellipsis.
- **Link (`.buttonStyle(.link)`):** quiet, in-line actions at footnote size: Learn more, Type an ID…, Cloud options…, and Delete/Cancel on model cards.
- **Borderless icon:** only the footer's `questionmark.circle` ("Take the tour again"), with a tooltip and an accessibility label.
- **Destructive:** `role: .destructive` on Delete and Remove, never a custom red fill.

### Mode Chooser (signature)
Three rows, each a plain button. A 24pt hierarchical SF Symbol at `.title3` sits on the left, the mode name in `.body` medium beside it, and the purpose line in secondary footnote below (plus "Best for…" in the tour). A trailing `circle` / `checkmark.circle.fill` sits on the right. The selected row gets an accent tint at 10% on an 8pt continuous rectangle and turns its symbol and check accent. Padding is 10pt horizontal and 8pt vertical, with 4pt between rows. Choosing a row replays that mode's caption demo in the preview beside or above it. The chooser is disabled while running.

### Caption Preview (signature)
A letterboxed dark frame: the scene gradient plus a warm radial glow, 8pt continuous corners, a black 25% hairline and the preview lift. It draws the real `CaptionLayer` at `frameWidth / screenWidth × 1.6`, with the user's live `CaptionStyle`. `CaptionDemo` performs each mode: Transcribe types words in at 260ms and settles them into a line, Translate drops the finished sentence whole, and Subtitle file runs a timecode chip (`link` symbol, `.caption2` mono medium, white 85% on a black 45% capsule, top-left) with lines swapping on cue. It replays on mode or language change. With Reduce Motion it shows one static line. It is 118pt in the panel, 150pt in the tour's mode step and 170pt on the welcome page. The Captions window uses a separate bright contrast scene (blue-to-sand gradient with a white disc) at true screen proportion, because its job is exposing contrast problems.

### Field Row
A label in the fixed 118pt column, then the control (labels hidden), left-aligned and filling the rest. Popups, segmented pickers (Speed) and the timing stepper all use it.

### Help Note
A secondary footnote under a control, one sentence, wrapping vertically and never truncated. It says what the control does or when to use it, in the viewer's words.

### Learn More
A link-style disclosure ("Learn more", "Why a subtitle file?", "How Translate works") with a small `chevron.right` that rotates 90° (ease-out 0.15s). The revealed content is secondary footnote text at 4pt spacing and fades in. Step content inside it uses `StepList`.

### Notice Row
A `Label` at footnote size: an SF Symbol plus a sentence. The **info** tone is a secondary glyph and secondary text. **Caution** is an orange glyph with primary text. **Done** is a green glyph with secondary text. It carries sync status ("In sync at 12:04."), cloud privacy ("Subtitle text is sent to OpenRouter. Audio never leaves the Mac."), estimates, rate-limit countdowns and errors.

### Step List
Numbered steps. Each has a 16pt accent disc with a white `.caption2` bold tabular numeral, baseline-aligned 8pt from the step sentence, with 6pt between steps. It is used for "How this works", the tour's mode step and the done screen.

### Cards / Containers
- **Corner Style:** 12pt continuous.
- **Background:** `controlBackgroundColor`.
- **Border:** 1pt primary at 8%. A selected model card uses a 1.5pt accent border.
- **Internal Padding:** 16pt (12pt compact in the tour).
- **Model card anatomy:** a headline name with capsule badges, a callout summary in secondary, green-check strengths, and a stats row (five-pip Speed/Accuracy meters, size, licence) in secondary footnote. A trailing 118pt action column holds Download / progress + Cancel / Use or "In use" / Delete.

### Badges
A `.caption2` semibold label in a capsule at 12% of its own colour, padded 6 by 2. There are three colours: accent (Recommended), secondary (English only), orange (Needs 16 GB, Non-commercial).

### Inputs / Fields
Native `.roundedBorder` text fields, `SecureField` for API keys, native popups and steppers, and `ColorPicker` and `Slider` inside grouped Forms. Slider readouts are secondary tabular text in a 52pt trailing column. A saved key is only ever shown masked (`key.fill` + "Key ••••1234 in your Keychain").

### Navigation
There is no custom navigation. The panel's footer opens windows by name. The tour uses Back / step dots (6pt circles, accent for the current step, primary 20% for the rest) / a prominent Continue in a footer bar under a divider. Page changes ease out over 0.2s.

## Do's and Don'ts

### Do:
- **Do** put a one-line `HelpNote` under every control that isn't self-evident, saying what it does in the viewer's words ("Skips lines the speech model wasn't sure about, instead of showing misheard words.").
- **Do** put longer explanation behind `LearnMore`, with a title that names the question ("Why a subtitle file?", "How Translate works").
- **Do** state status as a sentence with an SF Symbol through `NoticeRow`, and use the caution tone only for things that cost time, money or capability.
- **Do** use SF Symbols with hierarchical rendering for lead glyphs (mode rows, capability rows, file and permission glyphs). Inline label icons stay monochrome.
- **Do** keep panel controls on the 118pt `FieldRow` label column; use `Form` with `.grouped` style where the window is wide enough.
- **Do** draw captions anywhere in the UI with the real `CaptionLayer` and the user's `CaptionStyle`, never a mock-up.
- **Do** mark selection with accent tint plus a checkmark, and add the `.isSelected` accessibility trait.
- **Do** name every privacy consequence plainly beside the choice that causes it ("Audio never leaves the Mac.").

### Don't:
- **Don't** hard-code chrome colours or fixed point sizes; use system semantic colours, the accent and text styles.
- **Don't** add a second prominent button to a surface.
- **Don't** add shadows to cards, rows or banners; the caption preview is the only lifted element.
- **Don't** introduce a second non-system surface in the panel or tour; the dark caption scene is the one exception, and the Captions window's contrast scene is its purpose-bound sibling.
- **Don't** replace `.link` buttons' system link colour with the accent, or restyle native controls.
