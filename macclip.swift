import AppKit
import ApplicationServices
import Carbon

private let hotKeySignature: OSType = 0x4D434C50 // 'MCLP'
private let hotKeyIDValue: UInt32 = 1

private func previewText(_ text: String, limit: Int = 120) -> String {
    let single = text
        .components(separatedBy: .newlines)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    if single.count <= limit {
        return single
    }
    let idx = single.index(single.startIndex, offsetBy: max(1, limit - 1))
    return String(single[..<idx]) + "…"
}

struct ClipItem {
    let text: String
    var pinned: Bool
}

final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    private var maxItems: Int
    private var changeCount: Int

    init(maxItems: Int = 20) {
        self.maxItems = maxItems
        self.changeCount = NSPasteboard.general.changeCount
    }

    func startPolling() {
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
    }

    private func captureIfChanged() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else {
            return
        }
        changeCount = pb.changeCount
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }
        push(text)
    }

    private func push(_ text: String) {
        if items.first?.text == text {
            return
        }

        var wasPinned = false
        if let idx = items.firstIndex(where: { $0.text == text }) {
            wasPinned = items[idx].pinned
            items.remove(at: idx)
        }

        let item = ClipItem(text: text, pinned: wasPinned)
        if item.pinned {
            items.insert(item, at: 0)
        } else {
            items.insert(item, at: firstUnpinnedIndex())
        }

        trimToLimit()
    }

    @discardableResult
    func togglePin(text: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.text == text }) else {
            return false
        }

        var item = items.remove(at: idx)
        item.pinned.toggle()

        if item.pinned {
            items.insert(item, at: 0)
        } else {
            items.insert(item, at: firstUnpinnedIndex())
        }

        return item.pinned
    }

    @discardableResult
    func remove(text: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.text == text }) else {
            return false
        }
        items.remove(at: idx)
        return true
    }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        changeCount = pb.changeCount
    }

    func setMaxItems(_ newLimit: Int) {
        maxItems = max(1, newLimit)
        trimToLimit()
    }

    private func firstUnpinnedIndex() -> Int {
        items.firstIndex(where: { !$0.pinned }) ?? items.count
    }

    private func trimToLimit() {
        while items.count > maxItems {
            if let idx = items.lastIndex(where: { !$0.pinned }) {
                items.remove(at: idx)
            } else {
                items.removeLast()
            }
        }
    }
}

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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Enter / keypad Enter
            onEnterPressed?(event)
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

final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel: HistoryPanel
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = ClickPasteTableView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No clipboard history yet")

    private var allItems: [ClipItem] = []
    private var filteredItems: [ClipItem] = []
    private let onCopy: (String) -> Void
    private let onPaste: (String) -> Void
    private let onTogglePin: (String) -> [ClipItem]
    private let onDelete: (String) -> [ClipItem]

    init(
        onCopy: @escaping (String) -> Void,
        onPaste: @escaping (String) -> Void,
        onTogglePin: @escaping (String) -> [ClipItem],
        onDelete: @escaping (String) -> [ClipItem]
    ) {
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete

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
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
    }

    func show(items: [ClipItem], near point: NSPoint) {
        allItems = items
        searchField.stringValue = ""
        applyFilter(selectingText: nil)
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

        let hint = NSTextField(labelWithString: "Enter: copy   Cmd+Enter: paste   Click 📋/📌/🗑   Esc: close")
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

    private func applyFilter(selectingText: String?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }

        tableView.reloadData()
        emptyLabel.isHidden = !filteredItems.isEmpty

        guard !filteredItems.isEmpty else {
            return
        }

        if let selectingText,
           let index = filteredItems.firstIndex(where: { $0.text == selectingText }) {
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

    private func copySelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else {
            return
        }
        onCopy(filteredItems[row].text)
    }

    private func pasteSelectedRow() {
        pasteRow(tableView.selectedRow)
    }

    private func pasteRow(_ row: Int) {
        guard row >= 0, row < filteredItems.count else {
            return
        }
        hide()
        onPaste(filteredItems[row].text)
    }

    private func toggleSelectedPin() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else {
            return
        }
        let item = filteredItems[row]
        allItems = onTogglePin(item.text)
        applyFilter(selectingText: item.text)
    }

    @objc private func pinButtonPressed(_ sender: NSButton) {
        let point = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.midY), to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0, row < filteredItems.count else {
            return
        }
        let text = filteredItems[row].text
        allItems = onTogglePin(text)
        applyFilter(selectingText: text)
    }

    @objc private func copyButtonPressed(_ sender: NSButton) {
        let point = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.midY), to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0, row < filteredItems.count else {
            return
        }
        let text = filteredItems[row].text
        onCopy(text)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func deleteButtonPressed(_ sender: NSButton) {
        let point = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.midY), to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0, row < filteredItems.count else {
            return
        }

        let fallbackText: String?
        if row + 1 < filteredItems.count {
            fallbackText = filteredItems[row + 1].text
        } else if row > 0 {
            fallbackText = filteredItems[row - 1].text
        } else {
            fallbackText = nil
        }

        let text = filteredItems[row].text
        allItems = onDelete(text)
        applyFilter(selectingText: fallbackText)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        pasteSelectedRow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("Cell")
        let item = filteredItems[row]
        let text = previewText(item.text, limit: 104)

        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let label = cell.viewWithTag(1001) as? NSTextField,
           let pinButton = cell.viewWithTag(1002) as? NSButton,
           let copyButton = cell.viewWithTag(1003) as? NSButton,
           let deleteButton = cell.viewWithTag(1004) as? NSButton {
            label.stringValue = text
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

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
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
        applyFilter(selectingText: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyChoices: [(title: String, keyCode: UInt32)] = [
        ("Option + V", UInt32(kVK_ANSI_V)),
        ("Option + C", UInt32(kVK_ANSI_C)),
        ("Option + X", UInt32(kVK_ANSI_X)),
        ("Option + Space", UInt32(kVK_Space))
    ]
    private let historyLimitChoices: [Int] = [10, 20, 30, 40, 50]
    private let historyLimitDefaultsKey = "macclip.historyLimit"

    private var currentHistoryLimit = 20
    private lazy var store = ClipboardStore(maxItems: currentHistoryLimit)
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyMenuItems: [UInt32: NSMenuItem] = [:]
    private var historyLimitMenuItems: [Int: NSMenuItem] = [:]
    private var currentHotKeyCode: UInt32 = UInt32(kVK_ANSI_V)
    private var lastFrontmostApp: NSRunningApplication?
    private var hasPromptedAccessibilityThisSession = false

    private lazy var panelController = ClipboardPanelController(
        onCopy: { [weak self] text in
            self?.store.copyToClipboard(text)
        },
        onPaste: { [weak self] text in
            self?.copyAndPaste(text)
        },
        onTogglePin: { [weak self] text in
            guard let self else { return [] }
            _ = self.store.togglePin(text: text)
            return self.store.items
        },
        onDelete: { [weak self] text in
            guard let self else { return [] }
            _ = self.store.remove(text: text)
            return self.store.items
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        currentHistoryLimit = loadSavedHistoryLimit()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        installHotKey()
        store.startPolling()
        _ = accessibilityGranted(prompt: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(systemSymbolName: "scissors", accessibilityDescription: "MacClip") {
            icon.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "✂︎"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory), keyEquivalent: ""))

        let hotkeyParent = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu(title: "Hotkey")
        for choice in hotkeyChoices {
            let item = NSMenuItem(title: choice.title, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(choice.keyCode)
            hotkeyMenu.addItem(item)
            hotkeyMenuItems[choice.keyCode] = item
        }
        hotkeyParent.submenu = hotkeyMenu
        menu.addItem(hotkeyParent)

        let limitParent = NSMenuItem(title: "History Limit", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu(title: "History Limit")
        for limit in historyLimitChoices {
            let item = NSMenuItem(title: "\(limit) items", action: #selector(changeHistoryLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            limitMenu.addItem(item)
            historyLimitMenuItems[limit] = item
        }
        limitParent.submenu = limitMenu
        menu.addItem(limitParent)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MacClip", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        refreshHotkeyMenuState()
        refreshHistoryLimitMenuState()
    }

    private func installHotKey() {
        installHotKeyEventHandler()
        registerCurrentHotKey()
    }

    private func installHotKeyEventHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

                var hk = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                if status == noErr && hk.signature == hotKeySignature && hk.id == hotKeyIDValue {
                    app.showHistory()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func registerCurrentHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIDValue)
        RegisterEventHotKey(
            currentHotKeyCode,
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func refreshHotkeyMenuState() {
        for (code, item) in hotkeyMenuItems {
            item.state = code == currentHotKeyCode ? .on : .off
        }
        statusItem.button?.toolTip = "MacClip: \(hotkeyTitle(for: currentHotKeyCode)) for history"
    }

    private func refreshHistoryLimitMenuState() {
        for (limit, item) in historyLimitMenuItems {
            item.state = limit == currentHistoryLimit ? .on : .off
        }
    }

    private func loadSavedHistoryLimit() -> Int {
        let saved = UserDefaults.standard.integer(forKey: historyLimitDefaultsKey)
        return historyLimitChoices.contains(saved) ? saved : 20
    }

    private func hotkeyTitle(for code: UInt32) -> String {
        hotkeyChoices.first(where: { $0.keyCode == code })?.title ?? "Option + ?"
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        let chosenCode = UInt32(sender.tag)
        guard chosenCode != currentHotKeyCode else {
            return
        }
        currentHotKeyCode = chosenCode
        registerCurrentHotKey()
        refreshHotkeyMenuState()
    }

    @objc private func changeHistoryLimit(_ sender: NSMenuItem) {
        let chosenLimit = sender.tag
        guard historyLimitChoices.contains(chosenLimit), chosenLimit != currentHistoryLimit else {
            return
        }
        currentHistoryLimit = chosenLimit
        UserDefaults.standard.set(chosenLimit, forKey: historyLimitDefaultsKey)
        store.setMaxItems(chosenLimit)
        refreshHistoryLimitMenuState()
    }

    @objc private func showHistory() {
        lastFrontmostApp = NSWorkspace.shared.frontmostApplication
        panelController.show(items: store.items, near: NSEvent.mouseLocation)
    }

    private func copyAndPaste(_ text: String) {
        store.copyToClipboard(text)

        guard accessibilityGranted(prompt: false) else {
            if !hasPromptedAccessibilityThisSession {
                hasPromptedAccessibilityThisSession = true
                _ = accessibilityGranted(prompt: true)
            }
            return
        }

        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            self.postCommandV()
        }
    }

    private func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }

    private func accessibilityGranted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
