import AppKit

final class HistoryPanel: NSPanel {
    var onEnter: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onTogglePin: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.keyCode == 35 { // Cmd+P
            onTogglePin?()
            return
        }

        switch event.keyCode {
        case 36, 76:
            onEnter?(event)
        case 53:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class ClickPasteTableView: NSTableView {
    var onPrimaryRowClick: ((Int) -> Void)?
    var onEnterPressed: ((NSEvent) -> Void)?
    var onSpacePressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Enter / keypad Enter
            onEnterPressed?(event)
        case 49: // Space
            onSpacePressed?()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)

        guard event.type == .leftMouseUp else {
            return
        }

        let local = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(local), hit is NSButton {
            return
        }

        let row = self.row(at: local)
        guard row >= 0 else {
            return
        }

        onPrimaryRowClick?(row)
    }
}

/// Resolves capture rows to display data without coupling the panel to the library.
struct CaptureRowProvider {
    let thumbnail: (UUID) -> NSImage?
    let summary: (UUID) -> String?
}

final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel: HistoryPanel
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = ClickPasteTableView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No clipboard history yet")

    private var allItems: [ClipItem] = []
    private var filteredItems: [ClipItem] = []
    private let captureRows: CaptureRowProvider
    private let onCopy: (ClipContent) -> Void
    private let onPaste: (ClipContent) -> Void
    private let onTogglePin: (ClipContent) -> [ClipItem]
    private let onDelete: (ClipContent) -> [ClipItem]
    private let onEditCapture: (UUID) -> Void

    init(
        captureRows: CaptureRowProvider,
        onCopy: @escaping (ClipContent) -> Void,
        onPaste: @escaping (ClipContent) -> Void,
        onTogglePin: @escaping (ClipContent) -> [ClipItem],
        onDelete: @escaping (ClipContent) -> [ClipItem],
        onEditCapture: @escaping (UUID) -> Void
    ) {
        self.captureRows = captureRows
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onEditCapture = onEditCapture

        panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        buildUI()
        tableView.onPrimaryRowClick = { [weak self] row in
            self?.pasteRow(row)
        }
        tableView.onEnterPressed = { [weak self] event in
            self?.handleEnter(event)
        }
        tableView.onSpacePressed = { [weak self] in
            self?.editSelectedCapture()
        }
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
    }

    func show(items: [ClipItem], near point: NSPoint) {
        allItems = items
        searchField.stringValue = ""
        applyFilter(selecting: nil)
        positionPanel(near: point)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(tableView)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.onEnter = { [weak self] event in
            self?.handleEnter(event)
        }
        panel.onEscape = { [weak self] in
            self?.hide()
        }
        panel.onTogglePin = { [weak self] in
            self?.toggleSelectedPin()
        }
    }

    private func buildUI() {
        let root = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active

        panel.contentView = root

        let content = NSView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search clipboard"
        searchField.delegate = self

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
        tableColumn.title = "Clipboard"
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        tableView.backgroundColor = .clear

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let hint = NSTextField(labelWithString: "⏎ copy   ⌘⏎ paste   Space edit capture   ⌘P pin   Esc close")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)

        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -10),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    private func displayText(for content: ClipContent) -> String {
        switch content {
        case .text(let text):
            return previewText(text, limit: 104)
        case .capture(let id):
            return captureRows.summary(id) ?? "Capture (missing)"
        }
    }

    private func applyFilter(selecting: ClipContent?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter { item in
                switch item.content {
                case .text(let text):
                    return text.localizedCaseInsensitiveContains(query)
                case .capture:
                    return displayText(for: item.content).localizedCaseInsensitiveContains(query)
                }
            }
        }

        tableView.reloadData()
        emptyLabel.isHidden = !filteredItems.isEmpty

        guard !filteredItems.isEmpty else {
            return
        }

        if let selecting,
           let index = filteredItems.firstIndex(where: { $0.content == selecting }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    private func positionPanel(near point: NSPoint) {
        let desiredSize = panel.frame.size
        var x = point.x - desiredSize.width / 2
        var y = point.y - 14

        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        if let frame = targetScreen?.visibleFrame {
            x = max(frame.minX + 8, min(x, frame.maxX - desiredSize.width - 8))
            y = max(frame.minY + 8, min(y, frame.maxY - desiredSize.height - 8))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func handleEnter(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            pasteSelectedRow()
            return
        }
        copySelectedRow()
    }

    private func selectedItem() -> ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else {
            return nil
        }
        return filteredItems[row]
    }

    private func copySelectedRow() {
        guard let item = selectedItem() else { return }
        onCopy(item.content)
    }

    private func pasteSelectedRow() {
        pasteRow(tableView.selectedRow)
    }

    private func pasteRow(_ row: Int) {
        guard row >= 0, row < filteredItems.count else {
            return
        }
        hide()
        onPaste(filteredItems[row].content)
    }

    private func editSelectedCapture() {
        guard let item = selectedItem(), case .capture(let id) = item.content else {
            return
        }
        hide()
        onEditCapture(id)
    }

    private func toggleSelectedPin() {
        guard let item = selectedItem() else { return }
        allItems = onTogglePin(item.content)
        applyFilter(selecting: item.content)
    }

    private func content(forButton sender: NSButton) -> ClipContent? {
        let point = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.midY), to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0, row < filteredItems.count else {
            return nil
        }
        return filteredItems[row].content
    }

    @objc private func pinButtonPressed(_ sender: NSButton) {
        guard let content = content(forButton: sender) else { return }
        allItems = onTogglePin(content)
        applyFilter(selecting: content)
    }

    @objc private func copyButtonPressed(_ sender: NSButton) {
        guard let content = content(forButton: sender) else { return }
        onCopy(content)
        if let index = filteredItems.firstIndex(where: { $0.content == content }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func deleteButtonPressed(_ sender: NSButton) {
        guard let content = content(forButton: sender),
              let row = filteredItems.firstIndex(where: { $0.content == content }) else {
            return
        }

        let fallback: ClipContent?
        if row + 1 < filteredItems.count {
            fallback = filteredItems[row + 1].content
        } else if row > 0 {
            fallback = filteredItems[row - 1].content
        } else {
            fallback = nil
        }

        allItems = onDelete(content)
        applyFilter(selecting: fallback)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        pasteSelectedRow()
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < filteredItems.count else {
            return 30
        }
        if case .capture = filteredItems[row].content {
            return 44
        }
        return 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]
        let isCapture: Bool
        if case .capture = item.content {
            isCapture = true
        } else {
            isCapture = false
        }
        let id = NSUserInterfaceItemIdentifier(isCapture ? "CaptureCell" : "TextCell")
        let text = displayText(for: item.content)

        var thumbnail: NSImage?
        if case .capture(let captureID) = item.content {
            thumbnail = captureRows.thumbnail(captureID)
        }

        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let label = cell.viewWithTag(1001) as? NSTextField,
           let pinButton = cell.viewWithTag(1002) as? NSButton,
           let copyButton = cell.viewWithTag(1003) as? NSButton,
           let deleteButton = cell.viewWithTag(1004) as? NSButton {
            label.stringValue = text
            (cell.viewWithTag(1005) as? NSImageView)?.image = thumbnail
            pinButton.title = item.pinned ? "📌" : "📍"
            pinButton.contentTintColor = item.pinned ? .systemYellow : .secondaryLabelColor
            pinButton.toolTip = item.pinned ? "Unpin" : "Pin"
            copyButton.toolTip = "Copy"
            deleteButton.toolTip = "Delete"
            deleteButton.contentTintColor = .systemRed
            return cell
        }

        let cell = NSTableCellView(frame: .zero)
        cell.identifier = id

        let label = NSTextField(labelWithString: text)
        label.tag = 1001
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let pinButton = NSButton(title: item.pinned ? "📌" : "📍", target: self, action: #selector(pinButtonPressed(_:)))
        pinButton.tag = 1002
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.isBordered = false
        pinButton.contentTintColor = item.pinned ? .systemYellow : .secondaryLabelColor
        pinButton.font = NSFont.systemFont(ofSize: 14)
        pinButton.toolTip = item.pinned ? "Unpin" : "Pin"

        let copyButton = NSButton(title: "📋", target: self, action: #selector(copyButtonPressed(_:)))
        copyButton.tag = 1003
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isBordered = false
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.font = NSFont.systemFont(ofSize: 14)
        copyButton.toolTip = "Copy"

        let deleteButton = NSButton(title: "🗑", target: self, action: #selector(deleteButtonPressed(_:)))
        deleteButton.tag = 1004
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .systemRed
        deleteButton.font = NSFont.systemFont(ofSize: 13)
        deleteButton.toolTip = "Delete"

        cell.addSubview(label)
        cell.addSubview(copyButton)
        cell.addSubview(pinButton)
        cell.addSubview(deleteButton)

        var labelLeading = cell.leadingAnchor.constraint(equalTo: cell.leadingAnchor)
        if isCapture {
            let thumbView = NSImageView()
            thumbView.tag = 1005
            thumbView.image = thumbnail
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = 4
            thumbView.layer?.masksToBounds = true
            thumbView.layer?.borderWidth = 1
            thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
            thumbView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(thumbView)
            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                thumbView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: 56),
                thumbView.heightAnchor.constraint(equalToConstant: 36)
            ])
            labelLeading = label.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10)
        } else {
            labelLeading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8)
        }

        NSLayoutConstraint.activate([
            labelLeading,
            label.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 18),

            pinButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),
            pinButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 18),

            deleteButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 18)
        ])

        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(selecting: nil)
    }
}
