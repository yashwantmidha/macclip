# MacClip → Snagit-style Capture Tool — Plan

## Vision
One menu-bar app: clipboard history (existing) + screen capture + annotation editor + capture library. Screen recording deferred to v2.

## Decisions
- V1 scope: capture, annotation editor, capture library. No recording.
- Clipboard history stays; captures merge into the same history/UI.
- Structure: SwiftPM package, multi-file. Keep npm distribution (`swift build -c release` in install script).

## Architecture

```
Package.swift                     # executable "macclip", platform: macOS 13+
Sources/macclip/
  main.swift
  App/
    AppDelegate.swift             # wiring, status menu
    Hotkeys.swift                 # Carbon hotkey registration (extract existing)
  Clipboard/
    ClipboardStore.swift          # existing store, ClipItem → enum .text / .capture(id)
    HistoryPanel.swift            # existing panel, rows render text or thumbnail
  Capture/
    CaptureService.swift          # v1: shell out to /usr/sbin/screencapture
  Editor/
    EditorWindow.swift
    CanvasView.swift              # image + vector annotation overlay
    AnnotationModel.swift         # Annotation enum: arrow, rect, ellipse, line, freehand, text, highlight, blur, badge
    ToolbarController.swift
  Library/
    CaptureLibrary.swift          # disk store + JSON index
    LibraryWindow.swift           # thumbnail grid
```

## Key technical choices

**Capture (v1): shell out to `screencapture`.**
- Region: `screencapture -i <file>`, window: `-iW`, full: plain. Apple draws the selection UI — free crosshair, window highlight, multi-display, Retina.
- Interactive `screencapture` needs **no Screen Recording TCC permission** — this is why v1 skips ScreenCaptureKit.
- ScreenCaptureKit migration happens in v2 when recording lands (recording *does* need the permission; unbundled SwiftPM binary can be granted it as long as the installed binary path is stable, e.g. `~/.macclip/bin/macclip`).

**Editor: vector annotations over bitmap.**
- Annotations are value-type structs redrawn every frame; never baked in until export → free move/edit/delete of each annotation.
- Undo: NSUndoManager snapshots of the annotation array.
- Blur/pixelate: region annotation rendered via CIPixellate on the underlying image crop.
- Export: flatten to PNG/JPEG; actions = copy to clipboard, save to file, reveal in Finder, drag-out from canvas.

**Library:**
- `~/Library/Application Support/MacClip/captures/<uuid>.png` + `index.json` (id, date, dims, source app, edited flag).
- Thumbnails cached alongside. Grid window; click → editor; right-click → copy/delete/reveal.
- History panel unified: text rows (existing) + capture rows (thumbnail preview); Enter/click behavior identical.

**Hotkeys:** extend existing Carbon setup. Defaults: `⌥V` history (unchanged), `⌥⇧R` region, `⌥⇧W` window, `⌥⇧F` full screen. All remappable via menu, persisted in UserDefaults.

## Milestones

1. **Restructure** — split `macclip.swift` into SwiftPM layout above. Zero behavior change. Update install script to `swift build -c release`.
2. **Capture core** — CaptureService, 3 hotkeys, capture → clipboard + library dir + notification. No editor yet.
3. **Library** — disk index, unified history panel rows, library grid window.
4. **Editor MVP** — open post-capture; crop, arrow, rect, ellipse, freehand, text; color+stroke picker; undo/redo; copy/save.
5. **Editor v2** — blur/pixelate, highlighter, step-number badges, resize/scale image.
6. **Later (v2+)** — ScreenCaptureKit migration, video/GIF recording, scrolling capture, Vision-based OCR "grab text", share extensions.

## Risks
- Editor is the bulk (~2–3k lines). Milestones 4–5 sized accordingly.
- Persisted image history = disk usage; cap library size, add "Clear library" menu item.
- Unbundled binary + TCC: fine for v1 (no permission needed); recording later may push toward a proper .app bundle + bundle ID.
