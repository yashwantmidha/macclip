# MacClip

macOS menu-bar tool: clipboard history + screen capture + annotation editor + capture library.

## Features

**Clipboard history**
- Global hotkey picker (default `Option + V`), searchable
- Pin, copy, paste, delete per item
- Configurable history limit (`10/20/30/40/50`), in-memory only

**Screen capture**
- `Option + Shift + R` region · `Option + Shift + W` window · `Option + Shift + F` full screen
- Uses the system capture UI (Apple's `screencapture`)
- Every capture lands in the clipboard, the history picker, the library, and `~/Pictures/MacClip/`

**Annotation editor**
- Opens after capture (toggleable in Settings)
- Tools: select, crop, arrow, rectangle, ellipse, line, freehand, text, highlighter, pixelate, step badges
- Annotations stay editable (vector) until export; `⌘Z` undo
- `⌘C` copy flattened · `⌘S` save PNG · drag the image out into any app
- Edits persist — reopen any capture from the library and keep editing

**Capture library** (`Option + Shift + L`)
- Day-grouped thumbnail grid, blue dot = edited
- Double-click to edit; right-click: Edit / Copy Image / Save As… / Reveal in Finder / Delete
- Capped at 100 captures, oldest-unedited evicted first; "Clear Library…" wipes all

## Install

```bash
npm i -g macclip
macclip install
```

Install with login autostart:

```bash
macclip install --autostart
```

Requires Xcode Command Line Tools (`swift`).

**Permissions** (both prompted on first use, both may reset after reinstall):
- *Screen & System Audio Recording* — asked on first capture (macOS 15+). Apple's boilerplate mentions audio; MacClip captures still images only, no audio, no video.
- *Accessibility* — needed only for auto-paste (`⌘⏎`). Plain copy works without it.

## Use

| Hotkey | Action |
|---|---|
| `⌥V` | Clipboard history picker |
| `⌥⇧R` | Capture region |
| `⌥⇧W` | Capture window |
| `⌥⇧F` | Capture full screen |
| `⌥⇧L` | Capture library |

In the history picker:

- `Enter` copy · `Cmd + Enter` (or double-click) paste · `Space` edit capture · `Cmd + P` pin · `Esc` close
- Row buttons: `📋` copy, `📌`/`📍` pin/unpin, `🗑` delete

Useful commands:

```bash
macclip start
macclip stop
macclip status
macclip autostart on
macclip autostart off
macclip uninstall
```

## Data

- Every capture is also saved as a PNG in `~/Pictures/MacClip/` ("Open Captures Folder" in the menu; toggle off in Settings)
- Library internals (originals + annotation sidecars + thumbnails) live in `~/Library/Application Support/MacClip/`
- Clipboard text history is in-memory only

## Development

```bash
swift build            # debug build
swift build -c release
./.build/debug/macclip # run from checkout
```

See `DESIGN.md` for architecture and `PLAN.md` for the roadmap (screen recording, ScreenCaptureKit, OCR are v2).
