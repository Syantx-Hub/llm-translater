---
version: 1
slug: "app-sources-subtitler-ui-controlpanel-swift"
primary_target: "app/Sources/Subtitler/UI/ControlPanel.swift"
related_targets: ["app/Sources/Subtitler/UI"]
---

# Surface brief: Subtitler app UI (all windows)

Mode: Operate. Audience: Burmese-speaking viewers (non-technical) plus the author learning AI engineering. Job: pick the right way to use Subtitler for what they're watching, set it up once, press Start, then watch the video. Constraints: native SwiftUI, Command Line Tools only (no @State macro), menu bar panel 360 pt wide, Burmese script needs room.

## Direction contract

THESIS: A first-party Mac utility where every control says what it's for, right where it sits; it refuses the bare form of unexplained pickers and jargon.
OWN-WORLD: macOS system materials and grouped forms, SF Symbols in one hierarchical rendering, the system accent, footnote help under each control, and one real caption preview (a letterboxed black frame with the real CaptionLayer) as the only non-system element.
STORY: The viewer learns the three ways to use Subtitler, picks the one for what they watch, sets it up, presses Start, and always knows what's happening.
FIRST VIEWPORT: The panel header shows status and Start; below it the caption preview demos the selected mode; then three mode rows (symbol, name, one-line purpose); the selected mode's settings follow with footnotes and a "How this works" disclosure.
FORM: pick card (my top-ranked grounded candidate), seed 9bf931c5. Signature interaction: choosing a mode replays that mode's demo in the preview.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
