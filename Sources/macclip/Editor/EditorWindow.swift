import AppKit

final class EditorWindow: NSWindow {
    var onCommand: ((EditorWindowController.Command) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let command = EditorWindowController.Command(event: event),
           firstResponderIsPlainView,
           onCommand?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let command = EditorWindowController.Command(event: event),
           firstResponderIsPlainView,
           onCommand?(command) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var firstResponderIsPlainView: Bool {
        !(firstResponder is NSText)
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    enum Command {
        case undo, redo, copy, save

        init?(event: NSEvent) {
            guard event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers?.lowercased() else {
                return nil
            }
            switch chars {
            case "z":
                self = event.modifierFlags.contains(.shift) ? .redo : .undo
            case "c":
                self = .copy
            case "s":
                self = .save
            default:
                return nil
            }
        }
    }

    let captureID: UUID
    private let library: CaptureLibrary
    private let canvas: CanvasView
    private var toolControl: NSSegmentedControl!
    private var strokeControl: NSSegmentedControl!
    private var swatchButtons: [NSButton] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private var onClose: ((EditorWindowController) -> Void)?

    private static let toolSymbols: [(EditorTool, String, String)] = [
        (.select, "cursorarrow", "Select"),
        (.crop, "crop", "Crop (⏎ applies)"),
        (.arrow, "arrow.up.right", "Arrow"),
        (.rect, "rectangle", "Rectangle"),
        (.ellipse, "circle", "Ellipse"),
        (.line, "line.diagonal", "Line"),
        (.freehand, "scribble", "Freehand"),
        (.text, "textformat", "Text"),
        (.highlight, "highlighter", "Highlighter"),
        (.blur, "drop", "Pixelate"),
        (.badge, "1.circle", "Step badge")
    ]

    private static let swatchColors: [NSColor] = [
        .systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white
    ]

    private static let strokeWidths: [CGFloat] = [2, 3.5, 5]

    init?(captureID: UUID, library: CaptureLibrary, onClose: @escaping (EditorWindowController) -> Void) {
        guard let image = library.image(for: captureID),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.captureID = captureID
        self.library = library
        self.onClose = onClose
        let document = library.document(for: captureID) ?? AnnotationDocument()
        self.canvas = CanvasView(baseImage: cgImage, document: document)

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 400)
        super.init(window: window)

        window.delegate = self
        window.title = windowTitle()
        window.isReleasedWhenClosed = false
        window.center()
        window.onCommand = { [weak self] command in
            self?.handle(command) ?? false
        }

        buildUI()
        canvas.onDocumentChange = { [weak self] in
            self?.refreshStatus()
        }
        canvas.onStatusChange = { [weak self] in
            self?.refreshStatus()
        }
        refreshStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else {
            return
        }

        // Tool picker
        toolControl = NSSegmentedControl(frame: .zero)
        toolControl.segmentCount = Self.toolSymbols.count
        toolControl.trackingMode = .selectOne
        toolControl.segmentStyle = .texturedRounded
        for (index, entry) in Self.toolSymbols.enumerated() {
            let image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.2)
            toolControl.setImage(image, forSegment: index)
            toolControl.setToolTip(entry.2, forSegment: index)
            toolControl.setWidth(34, forSegment: index)
        }
        toolControl.selectedSegment = Self.toolSymbols.firstIndex(where: { $0.0 == .arrow }) ?? 0
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        // Swatches
        for (index, color) in Self.swatchColors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(swatchPressed(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 8
            button.layer?.borderWidth = index == 0 ? 2.5 : 1
            button.layer?.borderColor = index == 0
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 16).isActive = true
            button.toolTip = "Annotation color"
            swatchButtons.append(button)
        }

        // Stroke width
        strokeControl = NSSegmentedControl(labels: ["Thin", "Medium", "Thick"], trackingMode: .selectOne, target: self, action: #selector(strokeChanged))
        strokeControl.selectedSegment = 1
        strokeControl.font = NSFont.systemFont(ofSize: 11)

        let saveButton = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        saveButton.bezelStyle = .rounded
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        copyButton.bezelStyle = .rounded

        let swatchStack = NSStackView(views: swatchButtons)
        swatchStack.spacing = 5

        let toolbar = NSStackView(views: [toolControl, swatchStack, strokeControl, NSView(), saveButton, copyButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let hintLabel = NSTextField(labelWithString: "⌘Z undo · ⌫ delete selection · drag empty area to drag image out")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [statusLabel, NSView(), hintLabel])
        statusRow.orientation = .horizontal
        statusRow.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 6, right: 14)
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(topSeparator)
        content.addSubview(canvas)
        content.addSubview(bottomSeparator)
        content.addSubview(statusRow)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            canvas.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func windowTitle() -> String {
        guard let record = library.record(for: captureID) else {
            return "Capture"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let edited = record.edited || !canvas.document.annotations.isEmpty || canvas.document.cropRect != nil
        return "Capture — \(formatter.string(from: record.createdAt))\(edited ? " · Edited" : "")"
    }

    private func refreshStatus() {
        let visible = canvas.visibleImageRect
        var parts = ["\(Int(visible.width)) × \(Int(visible.height)) px"]
        let count = canvas.document.annotations.count
        if count > 0 {
            parts.append("\(count) annotation\(count == 1 ? "" : "s")")
        }
        if canvas.document.cropRect != nil {
            parts.append("cropped")
        }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        window?.title = windowTitle()
    }

    // MARK: - Actions

    @objc private func toolChanged() {
        let index = toolControl.selectedSegment
        guard index >= 0, index < Self.toolSymbols.count else {
            return
        }
        canvas.tool = Self.toolSymbols[index].0
        window?.makeFirstResponder(canvas)
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        guard sender.tag < Self.swatchColors.count else {
            return
        }
        canvas.style.color = CodableColor(Self.swatchColors[sender.tag])
        for (index, button) in swatchButtons.enumerated() {
            button.layer?.borderWidth = index == sender.tag ? 2.5 : 1
            button.layer?.borderColor = index == sender.tag
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func strokeChanged() {
        let index = strokeControl.selectedSegment
        guard index >= 0, index < Self.strokeWidths.count else {
            return
        }
        canvas.style.strokeWidth = Self.strokeWidths[index]
        canvas.style.fontSize = 14 + Self.strokeWidths[index] * 2
        window?.makeFirstResponder(canvas)
    }

    @objc private func copyPressed() {
        _ = handle(.copy)
    }

    @objc private func savePressed() {
        _ = handle(.save)
    }

    private func handle(_ command: Command) -> Bool {
        switch command {
        case .undo:
            guard canvas.undoManager?.canUndo == true else { return false }
            canvas.undoManager?.undo()
            return true
        case .redo:
            guard canvas.undoManager?.canRedo == true else { return false }
            canvas.undoManager?.redo()
            return true
        case .copy:
            guard let image = flattened() else { return false }
            NSPasteboard.general.setImageAllFlavors(image)
            return true
        case .save:
            saveToDisk()
            return true
        }
    }

    private func flattened() -> NSImage? {
        canvas.commitTextEditing()
        return AnnotationRenderer.flatten(
            base: canvas.baseImage,
            document: canvas.document,
            blurImage: { [weak self] in self?.canvas.currentBlurImage(for: $0) }
        )
    }

    private func saveToDisk() {
        guard let window, let image = flattened(), let png = AnnotationRenderer.pngData(image) else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let created = library.record(for: captureID)?.createdAt ?? Date()
        panel.nameFieldStringValue = "Capture \(formatter.string(from: created)).png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            try? png.write(to: url, options: .atomic)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        library.markEdited(captureID, document: canvas.document)
        if let image = flattened() {
            library.updateThumbnail(for: captureID, with: image)
        }
        let callback = onClose
        onClose = nil
        callback?(self)
    }
}
