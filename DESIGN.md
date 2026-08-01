# MacClip — Technical Design (Snagit-style v1)

Companion to `PLAN.md` (vision + milestones) and the UI mockups artifact. This doc is the implementation contract.

## 1. Module map (SwiftPM)

```
Package.swift                       # executable "macclip", .macOS(.v13)
Sources/macclip/
  main.swift                        # NSApplication bootstrap (last 5 lines of today's file)
  App/
    AppDelegate.swift               # status item, menu, wiring
    Hotkeys.swift                   # Carbon hotkey manager (generalized)
  Clipboard/
    ClipboardStore.swift            # store + polling
    HistoryPanel.swift              # panel + table (HistoryPanel, ClickPasteTableView, ClipboardPanelController)
  Capture/
    CaptureService.swift            # screencapture subprocess wrapper
  Editor/
    EditorWindow.swift              # NSWindowController, toolbar, actions
    CanvasView.swift                # draw + hit-test + drag
    AnnotationModel.swift           # Annotation types, AnnotationDocument
  Library/
    CaptureLibrary.swift            # disk store, index, thumbnails, eviction
    LibraryWindow.swift             # grid window
```

**Moves verbatim from `macclip.swift`:** `ClipboardStore` internals, `HistoryPanel`, `ClickPasteTableView`, most of `ClipboardPanelController`, `postCommandV`, accessibility helpers.

**Changes:** `ClipItem` (see §2), hotkey code generalized from one hardcoded ID to a table (see §6), `AppDelegate` menu grows capture items.

## 2. Data model

```swift
enum ClipContent: Equatable {
    case text(String)
    case capture(UUID)          // resolved via CaptureLibrary
}

struct ClipItem {
    let content: ClipContent
    var pinned: Bool
}
```

- Dedup/equality: text by string; capture by UUID.
- Clipboard polling additionally watches `NSPasteboard` for `.tiff`/`.png` types? **No** — v1 only MacClip-originated captures enter history as `.capture`; external image copies are ignored (avoids storing arbitrary pasted images). Revisit in v2.

```swift
struct AnnotationStyle: Codable {
    var color: CodableColor      // stored as sRGB components
    var strokeWidth: CGFloat     // 2 / 3.5 / 5
    var fontSize: CGFloat        // text tool only
}

enum Annotation: Codable, Identifiable {
    case arrow(id: UUID, from: CGPoint, to: CGPoint, style: AnnotationStyle)
    case rect(id: UUID, frame: CGRect, style: AnnotationStyle)
    case ellipse(id: UUID, frame: CGRect, style: AnnotationStyle)
    case line(id: UUID, from: CGPoint, to: CGPoint, style: AnnotationStyle)
    case freehand(id: UUID, points: [CGPoint], style: AnnotationStyle)
    case text(id: UUID, origin: CGPoint, string: String, style: AnnotationStyle)
    case highlight(id: UUID, frame: CGRect, style: AnnotationStyle)   // multiply-blend yellow
    case blur(id: UUID, frame: CGRect, scale: CGFloat)                // CIPixellate
    case badge(id: UUID, center: CGPoint, number: Int, style: AnnotationStyle)
}

struct AnnotationDocument: Codable {
    var annotations: [Annotation]
    var cropRect: CGRect?        // nil = uncropped
    var nextBadgeNumber: Int
}
```

Coordinates in **image pixel space**, origin bottom-left (AppKit). Canvas view converts to view space via its zoom/fit transform.

## 3. Rendering pipeline (Editor)

- `CanvasView` (NSView, `wantsLayer`): draws base `CGImage`, then iterates `annotations` in order in `draw(_:)`. No baking until export.
- **Blur**: on annotation add/move, render `CIPixellate(scale:)` of the underlying image crop into a cached `CGImage`; draw cached result. Cache invalidates on move/resize.
- **Hit-testing**: reverse iteration (topmost first); shapes use 6 px-inflated stroke paths, arrows/lines distance-to-segment, text/badge bounding boxes. Selected annotation draws dashed outline + 4 corner handles.
- **Undo**: `NSUndoManager` registers full `AnnotationDocument` snapshots per mutation. Cheap (value types), correct by construction.
- **Crop**: crop tool sets `cropRect` overlay; ⏎ applies (non-destructive — stored in document, applied at draw + export).
- **Export**: `NSImage` lockFocus at image pixel size → draw base + annotations with crop applied → PNG via `NSBitmapImageRep`. Actions: ⌘C copy, ⌘S save panel, drag-out (`NSDraggingSource` with file promise).
- Closing the window persists `AnnotationDocument` as sidecar JSON in the library → edits stay editable.

## 4. Capture flow

```swift
final class CaptureService {
    enum Mode { case region, window, fullscreen }
    func capture(_ mode: Mode) async -> URL?   // temp png path, nil if user cancelled
}
```

- Shells out to `/usr/sbin/screencapture`: region `-i`, window `-iW`, fullscreen no flag; always `-x` (no sound handled by system), output to temp file in `NSTemporaryDirectory()`.
- Cancelled selection → empty/missing file → return nil, no side effects.
- Permissions: on macOS 15+ the first capture triggers the Screen & System Audio Recording consent prompt ("bypass the system private window picker…") — macOS attributes the `screencapture` child to MacClip. One-time Allow; the wording mentions audio because that's the permission bucket's name, but MacClip uses no audio APIs. Accessibility permission (paste synthesis) is separate and also required. Both grants can reset when the binary is replaced (unsigned).
- On success: `CaptureLibrary.add(url)` → history gets `.capture(id)` → image also written to `NSPasteboard` → editor opens if the "Open editor after capture" default is on (default: on).
- v2 replaces internals with ScreenCaptureKit when recording lands; `CaptureService` API is the seam.

## 5. Library storage

```
~/Library/Application Support/MacClip/
  captures/<uuid>.png              # original capture, never mutated
  captures/<uuid>.annotations.json # sidecar, present iff edited
  thumbs/<uuid>.png                # 320px-wide thumbnail
  index.json                       # [CaptureRecord]
```

```swift
struct CaptureRecord: Codable {
    let id: UUID
    let createdAt: Date
    let pixelSize: CGSize
    var edited: Bool
}
```

- `CaptureLibrary` is the single owner: add, delete, list, thumbnail(id), image(id), document(id). Serial queue for disk I/O; index rewritten atomically.
- **Eviction**: cap = 100 captures (configurable), oldest-unedited first; edited captures evicted only when everything unedited is gone. "Clear Library…" = NSAlert confirm → wipe dir.
- History `.capture` rows whose file was evicted are dropped from history on resolve failure.

## 6. Hotkeys

Generalize existing Carbon code (`installHotKey` / `registerCurrentHotKey`) into:

```swift
struct HotkeyBinding { let id: UInt32; let keyCode: UInt32; let modifiers: UInt32 }
final class HotkeyManager {           // one Carbon handler dispatching on EventHotKeyID.id
    func register(_ bindings: [HotkeyBinding], handler: @escaping (UInt32) -> Void)
}
```

Defaults: `⌥V` history (id 1, unchanged) · `⌥⇧R` region (2) · `⌥⇧W` window (3) · `⌥⇧F` full (4) · `⌥⇧L` library (5). Remap UI stays menu-based like today; persisted in UserDefaults.

## 7. UI contracts (see mockups artifact)

- **Status menu**: capture items first, then Show History, Library…, Settings submenu (absorbs Hotkey + History Limit + new toggles), Quit.
- **Editor**: one toolbar row — select, crop ‖ arrow (default active), rect, ellipse, line, freehand, text, highlighter, blur, badge ‖ 6 swatches, 3 stroke widths ‖ Save…, Copy. Status bar: dimensions, annotation count, hints.
- **History panel**: unchanged shape; capture rows = 56×36 thumbnail + "Capture · time · WxH · edited". Enter copy, ⌘Enter paste, **Space opens editor** (new), ⌘P pin, esc close.
- **Library window**: regular window, day-grouped 4-col grid, blue dot = edited, double-click edit, context menu (Edit / Copy Image / Save As… / Reveal in Finder / Delete), toolbar Clear Library… + search (v1: date/dimensions filter).

## 8. Build & distribution

- `swift build -c release` replaces single-file `swiftc` in `install_macclip.sh`; binary still installed to the stable path the script uses today (keeps any future TCC grants sticky).
- npm wrapper (`bin/macclip.js`, `package.json`) unchanged in interface.
- No bundle/notarization in v1. Recording in v2 likely forces a real `.app` bundle + bundle ID; noted as accepted future cost.

## 9. Non-goals (v1)

Screen recording, scrolling capture, OCR/grab-text, external-image clipboard history, iCloud sync, share extensions.
