import AppKit

enum EditorTool: Int {
    case select, crop, arrow, rect, ellipse, line, freehand, text, highlight, blur, badge
}

final class CanvasView: NSView, NSTextFieldDelegate {
    let baseImage: CGImage
    var document: AnnotationDocument {
        didSet {
            if document != oldValue {
                onDocumentChange?()
            }
            rebuildStaleBlurCaches()
            needsDisplay = true
        }
    }

    var tool: EditorTool = .arrow {
        didSet {
            pendingCrop = nil
            if tool != .select {
                selectedID = nil
            }
            commitTextEditing()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var style: AnnotationStyle = .default
    var onDocumentChange: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private(set) var selectedID: UUID?
    private var draft: Annotation?
    private var pendingCrop: CGRect?
    private var dragStart: CGPoint = .zero
    private var isMovingSelection = false
    private var didDragOut = false
    private var blurCache: [UUID: CGImage] = [:]
    private var textField: NSTextField?
    private var editingTextID: UUID?

    private let editorUndoManager = UndoManager()
    override var undoManager: UndoManager? { editorUndoManager }
    override var acceptsFirstResponder: Bool { true }

    init(baseImage: CGImage, document: AnnotationDocument) {
        self.baseImage = baseImage
        self.document = document
        super.init(frame: .zero)
        rebuildStaleBlurCaches()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    private var fullImageRect: CGRect {
        CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
    }

    /// Portion of the image currently shown (crop applied).
    var visibleImageRect: CGRect {
        document.cropRect ?? fullImageRect
    }

    /// Uniform scale that fits the visible image inside the view, centered.
    private var fitTransform: (scale: CGFloat, offset: CGPoint) {
        let visible = visibleImageRect
        guard visible.width > 0, visible.height > 0, bounds.width > 8, bounds.height > 8 else {
            return (1, .zero)
        }
        let inset: CGFloat = 16
        let availW = bounds.width - inset * 2
        let availH = bounds.height - inset * 2
        let scale = min(availW / visible.width, availH / visible.height, 1)
        let drawnW = visible.width * scale
        let drawnH = visible.height * scale
        let offset = CGPoint(
            x: (bounds.width - drawnW) / 2 - visible.origin.x * scale,
            y: (bounds.height - drawnH) / 2 - visible.origin.y * scale
        )
        return (scale, offset)
    }

    func viewPoint(fromImage p: CGPoint) -> CGPoint {
        let t = fitTransform
        return CGPoint(x: p.x * t.scale + t.offset.x, y: p.y * t.scale + t.offset.y)
    }

    func imagePoint(fromView p: CGPoint) -> CGPoint {
        let t = fitTransform
        guard t.scale > 0 else { return p }
        return CGPoint(x: (p.x - t.offset.x) / t.scale, y: (p.y - t.offset.y) / t.scale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }

        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        bounds.fill()

        let t = fitTransform
        ctx.saveGState()

        // Clip to the visible (cropped) area in view space.
        let visible = visibleImageRect
        let visibleViewRect = CGRect(
            x: visible.origin.x * t.scale + t.offset.x,
            y: visible.origin.y * t.scale + t.offset.y,
            width: visible.width * t.scale,
            height: visible.height * t.scale
        )
        NSColor.black.withAlphaComponent(0.25).setFill()
        visibleViewRect.insetBy(dx: -1, dy: -1).fill()
        ctx.clip(to: visibleViewRect)

        ctx.translateBy(x: t.offset.x, y: t.offset.y)
        ctx.scaleBy(x: t.scale, y: t.scale)
        ctx.interpolationQuality = .high

        AnnotationRenderer.drawBase(baseImage, in: ctx)
        AnnotationRenderer.draw(document.annotations, in: ctx) { [weak self] a in
            self?.blurCache[a.id]
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: ctx) { _ in nil }
        }
        ctx.restoreGState()

        drawSelectionChrome(t: t)
        drawCropChrome(viewVisible: visibleViewRect)
    }

    private func drawSelectionChrome(t: (scale: CGFloat, offset: CGPoint)) {
        guard let selectedID,
              let annotation = document.annotations.first(where: { $0.id == selectedID }) else {
            return
        }
        let box = annotation.boundingBox.insetBy(dx: -4, dy: -4)
        let viewBox = CGRect(
            x: box.origin.x * t.scale + t.offset.x,
            y: box.origin.y * t.scale + t.offset.y,
            width: box.width * t.scale,
            height: box.height * t.scale
        )

        let path = NSBezierPath(rect: viewBox)
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        for corner in [
            CGPoint(x: viewBox.minX, y: viewBox.minY),
            CGPoint(x: viewBox.maxX, y: viewBox.minY),
            CGPoint(x: viewBox.minX, y: viewBox.maxY),
            CGPoint(x: viewBox.maxX, y: viewBox.maxY)
        ] {
            let handle = CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: handle).stroke()
        }
    }

    private func drawCropChrome(viewVisible: CGRect) {
        guard tool == .crop, let pendingCrop else {
            return
        }
        let t = fitTransform
        let cropView = CGRect(
            x: pendingCrop.origin.x * t.scale + t.offset.x,
            y: pendingCrop.origin.y * t.scale + t.offset.y,
            width: pendingCrop.width * t.scale,
            height: pendingCrop.height * t.scale
        )

        // Dim everything outside the pending crop.
        let dim = NSBezierPath(rect: viewVisible)
        dim.append(NSBezierPath(rect: cropView).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: cropView)
        outline.lineWidth = 1.5
        outline.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        let viewP = convert(event.locationInWindow, from: nil)
        let p = clampedToVisible(imagePoint(fromView: viewP))
        dragStart = p
        didDragOut = false

        switch tool {
        case .select:
            if let hit = hitTest(imagePoint: p) {
                if event.clickCount == 2 && hit.kind == .text {
                    selectedID = nil
                    editTextAnnotation(hit)
                    return
                }
                selectedID = hit.id
                isMovingSelection = true
                registerUndoSnapshot()
            } else {
                selectedID = nil
                isMovingSelection = false
            }
            needsDisplay = true
            onStatusChange?()

        case .crop:
            pendingCrop = CGRect(origin: p, size: .zero)

        case .text:
            beginTextEditing(at: p, existing: nil)

        case .badge:
            registerUndoSnapshot()
            var doc = document
            let annotation = Annotation(kind: .badge, style: style, from: p, number: doc.nextBadgeNumber)
            doc.annotations.append(annotation)
            doc.nextBadgeNumber += 1
            document = doc

        case .arrow, .rect, .ellipse, .line, .highlight, .blur:
            draft = Annotation(kind: kind(for: tool), style: style, from: p, to: p)

        case .freehand:
            draft = Annotation(kind: .freehand, style: style, points: [p])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewP = convert(event.locationInWindow, from: nil)
        let p = clampedToVisible(imagePoint(fromView: viewP))

        switch tool {
        case .select:
            if isMovingSelection, let selectedID,
               let idx = document.annotations.firstIndex(where: { $0.id == selectedID }) {
                let delta = CGPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
                dragStart = p
                var doc = document
                doc.annotations[idx].translate(by: delta)
                document = doc
            } else if selectedID == nil && !didDragOut {
                let raw = imagePoint(fromView: viewP)
                if hypot(raw.x - dragStart.x, raw.y - dragStart.y) > 6 {
                    didDragOut = true
                    beginDragOut(event: event)
                }
            }

        case .crop:
            pendingCrop = rect(from: dragStart, to: p)
            needsDisplay = true

        case .text, .badge:
            break

        default:
            guard var d = draft else { return }
            if d.kind == .freehand {
                d.points.append(p)
            } else {
                d.to = p
            }
            draft = d
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isMovingSelection = false
            didDragOut = false
        }

        switch tool {
        case .select:
            if isMovingSelection {
                refreshBlurForSelection()
            }

        case .crop:
            if let c = pendingCrop, c.width < 4 || c.height < 4 {
                pendingCrop = nil
                needsDisplay = true
            }

        default:
            guard let d = draft else { return }
            draft = nil
            let tooSmall: Bool
            switch d.kind {
            case .freehand:
                tooSmall = d.points.count < 2
            default:
                tooSmall = hypot(d.to.x - d.from.x, d.to.y - d.from.y) < 4
            }
            guard !tooSmall else {
                needsDisplay = true
                return
            }

            registerUndoSnapshot()
            var doc = document
            doc.annotations.append(d)
            document = doc
            if d.kind == .blur {
                blurCache[d.id] = AnnotationRenderer.pixellated(from: baseImage, rect: d.normalizedRect)
                needsDisplay = true
            }
        }
        onStatusChange?()
    }

    override func resetCursorRects() {
        switch tool {
        case .select:
            addCursorRect(bounds, cursor: .arrow)
        default:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete / forward delete
            deleteSelection()
        case 53: // escape
            if pendingCrop != nil {
                pendingCrop = nil
                needsDisplay = true
            } else if selectedID != nil {
                selectedID = nil
                needsDisplay = true
            } else {
                super.keyDown(with: event)
            }
        case 36, 76: // return
            if tool == .crop, pendingCrop != nil {
                applyPendingCrop()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    func deleteSelection() {
        guard let selectedID else { return }
        registerUndoSnapshot()
        var doc = document
        doc.annotations.removeAll(where: { $0.id == selectedID })
        document = doc
        blurCache.removeValue(forKey: selectedID)
        self.selectedID = nil
        onStatusChange?()
    }

    func applyPendingCrop() {
        guard let pendingCrop, pendingCrop.width >= 4, pendingCrop.height >= 4 else {
            return
        }
        registerUndoSnapshot()
        var doc = document
        doc.cropRect = pendingCrop.intersection(visibleImageRect)
        document = doc
        self.pendingCrop = nil
        onStatusChange?()
    }

    func resetCrop() {
        guard document.cropRect != nil else { return }
        registerUndoSnapshot()
        var doc = document
        doc.cropRect = nil
        document = doc
        onStatusChange?()
    }

    // MARK: - Undo

    private func registerUndoSnapshot() {
        let snapshot = document
        editorUndoManager.registerUndo(withTarget: self) { canvas in
            canvas.registerUndoSnapshot() // makes redo work symmetrically
            canvas.document = snapshot
            canvas.selectedID = nil
            canvas.onStatusChange?()
        }
    }

    // MARK: - Text editing

    private func beginTextEditing(at imageP: CGPoint, existing: Annotation?) {
        commitTextEditing()

        let field = NSTextField(string: existing?.string ?? "")
        field.font = NSFont.boldSystemFont(ofSize: max(13, style.fontSize * fitTransform.scale))
        field.textColor = (existing?.style ?? style).color.nsColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = self
        field.placeholderString = "Text"

        let anchorView = viewPoint(fromImage: existing?.from ?? imageP)
        field.frame = NSRect(x: anchorView.x, y: anchorView.y - 24, width: 220, height: 24)
        addSubview(field)
        window?.makeFirstResponder(field)

        textField = field
        editingTextID = existing?.id
        if existing == nil {
            dragStart = imageP
        }
    }

    func editTextAnnotation(_ annotation: Annotation) {
        guard annotation.kind == .text else { return }
        beginTextEditing(at: annotation.from, existing: annotation)
    }

    func commitTextEditing() {
        guard let field = textField else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedID = editingTextID
        textField = nil
        editingTextID = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        var doc = document
        if let editedID, let idx = doc.annotations.firstIndex(where: { $0.id == editedID }) {
            registerUndoSnapshot()
            if string.isEmpty {
                doc.annotations.remove(at: idx)
            } else {
                doc.annotations[idx].string = string
            }
            document = doc
        } else if !string.isEmpty {
            registerUndoSnapshot()
            doc.annotations.append(Annotation(kind: .text, style: style, from: dragStart, string: string))
            document = doc
        }
        onStatusChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    // MARK: - Hit testing

    private func hitTest(imagePoint p: CGPoint) -> Annotation? {
        let slop = 8 / max(fitTransform.scale, 0.05)
        for annotation in document.annotations.reversed() {
            switch annotation.kind {
            case .line, .arrow:
                if distanceToSegment(p, annotation.from, annotation.to) < slop {
                    return annotation
                }
            case .freehand:
                var prev: CGPoint?
                for point in annotation.points {
                    if let prev, distanceToSegment(p, prev, point) < slop {
                        return annotation
                    }
                    prev = point
                }
            default:
                if annotation.boundingBox.insetBy(dx: -slop, dy: -slop).contains(p) {
                    return annotation
                }
            }
        }
        return nil
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSq = abx * abx + aby * aby
        guard lengthSq > 0 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq))
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // MARK: - Drag out

    private func beginDragOut(event: NSEvent) {
        guard let flattened = AnnotationRenderer.flatten(
            base: baseImage,
            document: document,
            blurImage: { [weak self] in self?.blurCache[$0.id] }
        ) else {
            return
        }

        let item = NSDraggingItem(pasteboardWriter: flattened)
        let dragSize = NSSize(width: 160, height: 160 * flattened.size.height / max(flattened.size.width, 1))
        let origin = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(origin: NSPoint(x: origin.x - dragSize.width / 2, y: origin.y - dragSize.height / 2), size: dragSize),
            contents: flattened
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - Blur cache upkeep

    private func refreshBlurForSelection() {
        guard let selectedID,
              let annotation = document.annotations.first(where: { $0.id == selectedID }),
              annotation.kind == .blur else {
            return
        }
        blurCache[annotation.id] = AnnotationRenderer.pixellated(from: baseImage, rect: annotation.normalizedRect)
        needsDisplay = true
    }

    private func rebuildStaleBlurCaches() {
        for annotation in document.annotations where annotation.kind == .blur {
            if blurCache[annotation.id] == nil {
                blurCache[annotation.id] = AnnotationRenderer.pixellated(from: baseImage, rect: annotation.normalizedRect)
            }
        }
    }

    func currentBlurImage(for annotation: Annotation) -> CGImage? {
        blurCache[annotation.id]
    }

    // MARK: - Helpers

    private func kind(for tool: EditorTool) -> AnnotationKind {
        switch tool {
        case .arrow: return .arrow
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .line: return .line
        case .freehand: return .freehand
        case .highlight: return .highlight
        case .blur: return .blur
        default: return .rect
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func clampedToVisible(_ p: CGPoint) -> CGPoint {
        let v = visibleImageRect
        return CGPoint(x: min(max(p.x, v.minX), v.maxX), y: min(max(p.y, v.minY), v.maxY))
    }
}

extension CanvasView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
