import AppKit
import ApplicationServices
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyChoices: [(title: String, keyCode: UInt32)] = [
        ("Option + V", UInt32(kVK_ANSI_V)),
        ("Option + C", UInt32(kVK_ANSI_C)),
        ("Option + X", UInt32(kVK_ANSI_X)),
        ("Option + Space", UInt32(kVK_Space))
    ]
    private let historyLimitChoices: [Int] = [10, 20, 30, 40, 50]
    private let historyLimitDefaultsKey = "macclip.historyLimit"
    private let openEditorDefaultsKey = "macclip.openEditorAfterCapture"
    private let mirrorCapturesDefaultsKey = "macclip.saveCopiesToPictures"

    static var picturesFolder: URL {
        FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacClip", isDirectory: true)
    }

    private var currentHistoryLimit = 20
    private lazy var store = ClipboardStore(maxItems: currentHistoryLimit)
    private let library = CaptureLibrary.shared
    private let captureService = CaptureService()
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private var hotkeyMenuItems: [UInt32: NSMenuItem] = [:]
    private var historyLimitMenuItems: [Int: NSMenuItem] = [:]
    private var openEditorMenuItem: NSMenuItem?
    private var mirrorCapturesMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var currentHotKeyCode: UInt32 = UInt32(kVK_ANSI_V)
    private var lastFrontmostApp: NSRunningApplication?
    private var hasPromptedAccessibilityThisSession = false

    private var editors: [UUID: EditorWindowController] = [:]
    private var libraryWindow: LibraryWindowController?

    private var openEditorAfterCapture: Bool {
        get {
            UserDefaults.standard.object(forKey: openEditorDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: openEditorDefaultsKey)
        }
    }

    private var mirrorCapturesToPictures: Bool {
        get {
            UserDefaults.standard.object(forKey: mirrorCapturesDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: mirrorCapturesDefaultsKey)
        }
    }

    private lazy var panelController = ClipboardPanelController(
        captureRows: CaptureRowProvider(
            thumbnail: { [weak self] id in
                self?.library.thumbnail(for: id) ?? self?.library.image(for: id)
            },
            summary: { [weak self] id in
                guard let record = self?.library.record(for: id) else {
                    return nil
                }
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                var parts = [
                    "Capture",
                    formatter.string(from: record.createdAt),
                    "\(record.pixelWidth)×\(record.pixelHeight)"
                ]
                if record.edited {
                    parts.append("edited")
                }
                return parts.joined(separator: " · ")
            }
        ),
        onCopy: { [weak self] content in
            self?.copyContent(content)
        },
        onPaste: { [weak self] content in
            self?.copyAndPaste(content)
        },
        onTogglePin: { [weak self] content in
            guard let self else { return [] }
            _ = self.store.togglePin(content: content)
            return self.store.items
        },
        onDelete: { [weak self] content in
            guard let self else { return [] }
            _ = self.store.remove(content: content)
            return self.store.items
        },
        onEditCapture: { [weak self] id in
            self?.openEditor(for: id)
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        currentHistoryLimit = loadSavedHistoryLimit()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        installHotkeys()
        store.startPolling()
        _ = accessibilityGranted(prompt: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
    }

    // MARK: - Status menu

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

        menu.addItem(menuItem("Capture Region", #selector(captureRegion), symbol: "camera"))
        menu.addItem(menuItem("Capture Window", #selector(captureWindow), symbol: "macwindow"))
        menu.addItem(menuItem("Capture Full Screen", #selector(captureFullscreen), symbol: "display"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Show History", #selector(showHistory), symbol: "clock"))
        menu.addItem(menuItem("Library…", #selector(showLibrary), symbol: "square.grid.2x2"))
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder), symbol: "folder"))
        menu.addItem(NSMenuItem.separator())

        let settingsParent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")

        let hotkeyParent = NSMenuItem(title: "History Hotkey", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu(title: "History Hotkey")
        for choice in hotkeyChoices {
            let item = NSMenuItem(title: choice.title, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(choice.keyCode)
            hotkeyMenu.addItem(item)
            hotkeyMenuItems[choice.keyCode] = item
        }
        hotkeyParent.submenu = hotkeyMenu
        settingsMenu.addItem(hotkeyParent)

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
        settingsMenu.addItem(limitParent)

        let openEditorItem = NSMenuItem(title: "Open Editor After Capture", action: #selector(toggleOpenEditor), keyEquivalent: "")
        openEditorItem.target = self
        settingsMenu.addItem(openEditorItem)
        openEditorMenuItem = openEditorItem

        let mirrorItem = NSMenuItem(title: "Save Copies to Pictures/MacClip", action: #selector(toggleMirrorCaptures), keyEquivalent: "")
        mirrorItem.target = self
        settingsMenu.addItem(mirrorItem)
        mirrorCapturesMenuItem = mirrorItem

        if LoginItem.isAvailable {
            let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem.target = self
            settingsMenu.addItem(loginItem)
            loginMenuItem = loginItem
        }

        settingsParent.submenu = settingsMenu
        menu.addItem(settingsParent)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MacClip", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        refreshHotkeyMenuState()
        refreshHistoryLimitMenuState()
        refreshOpenEditorMenuState()
        refreshMirrorCapturesMenuState()
        refreshLoginMenuState()
    }

    private func menuItem(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    // MARK: - Hotkeys

    private func installHotkeys() {
        hotkeys.onHotkey = { [weak self] id in
            guard let self else { return }
            switch id {
            case HotkeyID.history:
                self.showHistory()
            case HotkeyID.captureRegion:
                self.captureRegion()
            case HotkeyID.captureWindow:
                self.captureWindow()
            case HotkeyID.captureFullscreen:
                self.captureFullscreen()
            case HotkeyID.library:
                self.showLibrary()
            default:
                break
            }
        }
        registerCurrentHotkeys()
    }

    private func registerCurrentHotkeys() {
        let optionShift = UInt32(optionKey | shiftKey)
        hotkeys.register([
            HotkeyBinding(id: HotkeyID.history, keyCode: currentHotKeyCode, modifiers: UInt32(optionKey)),
            HotkeyBinding(id: HotkeyID.captureRegion, keyCode: UInt32(kVK_ANSI_R), modifiers: optionShift),
            HotkeyBinding(id: HotkeyID.captureWindow, keyCode: UInt32(kVK_ANSI_W), modifiers: optionShift),
            HotkeyBinding(id: HotkeyID.captureFullscreen, keyCode: UInt32(kVK_ANSI_F), modifiers: optionShift),
            HotkeyBinding(id: HotkeyID.library, keyCode: UInt32(kVK_ANSI_L), modifiers: optionShift)
        ])
    }

    // MARK: - Capture

    @objc private func captureRegion() {
        runCapture(.region)
    }

    @objc private func captureWindow() {
        runCapture(.window)
    }

    @objc private func captureFullscreen() {
        runCapture(.fullscreen)
    }

    private func runCapture(_ mode: CaptureService.Mode) {
        captureService.capture(mode) { [weak self] url in
            guard let self, let url, let record = self.library.add(tempFile: url) else {
                return
            }
            self.store.addCapture(record.id)
            if let image = self.library.image(for: record.id) {
                self.store.copyImageToClipboard(image)
            }
            if self.mirrorCapturesToPictures {
                self.mirrorCapture(record)
            }
            if self.openEditorAfterCapture {
                self.openEditor(for: record.id)
            }
        }
    }

    /// Copies the capture PNG into ~/Pictures/MacClip with a readable name.
    private func mirrorCapture(_ record: CaptureRecord) {
        let folder = Self.picturesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let destination = folder.appendingPathComponent("Capture \(formatter.string(from: record.createdAt)).png")
        try? FileManager.default.copyItem(at: library.imageURL(record.id), to: destination)
    }

    @objc private func openCapturesFolder() {
        let folder = Self.picturesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Editor / Library windows

    func openEditor(for id: UUID) {
        if let existing = editors[id] {
            existing.showWindow(nil)
            return
        }
        guard let controller = EditorWindowController(
            captureID: id,
            library: library,
            onClose: { [weak self] controller in
                self?.editors.removeValue(forKey: controller.captureID)
            }
        ) else {
            return
        }
        editors[id] = controller
        controller.showWindow(nil)
    }

    @objc private func showLibrary() {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController(library: library) { [weak self] id in
                self?.openEditor(for: id)
            }
        }
        libraryWindow?.showWindow(nil)
    }

    // MARK: - Menu state

    private func refreshHotkeyMenuState() {
        for (code, item) in hotkeyMenuItems {
            item.state = code == currentHotKeyCode ? .on : .off
        }
        statusItem.button?.toolTip = "MacClip: \(hotkeyTitle(for: currentHotKeyCode)) for history, ⌥⇧R to capture"
    }

    private func refreshHistoryLimitMenuState() {
        for (limit, item) in historyLimitMenuItems {
            item.state = limit == currentHistoryLimit ? .on : .off
        }
    }

    private func refreshOpenEditorMenuState() {
        openEditorMenuItem?.state = openEditorAfterCapture ? .on : .off
    }

    private func refreshMirrorCapturesMenuState() {
        mirrorCapturesMenuItem?.state = mirrorCapturesToPictures ? .on : .off
    }

    @objc private func toggleMirrorCaptures() {
        mirrorCapturesToPictures.toggle()
        refreshMirrorCapturesMenuState()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        refreshLoginMenuState()
    }

    private func refreshLoginMenuState() {
        loginMenuItem?.state = LoginItem.isEnabled ? .on : .off
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
        registerCurrentHotkeys()
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

    @objc private func toggleOpenEditor() {
        openEditorAfterCapture.toggle()
        refreshOpenEditorMenuState()
    }

    @objc private func showHistory() {
        lastFrontmostApp = NSWorkspace.shared.frontmostApplication
        store.removeCaptures(notIn: Set(library.records.map(\.id)))
        panelController.show(items: store.items, near: NSEvent.mouseLocation)
    }

    // MARK: - Copy / paste

    private func copyContent(_ content: ClipContent) {
        switch content {
        case .text(let text):
            store.copyToClipboard(text)
        case .capture(let id):
            guard let image = library.image(for: id) else {
                return
            }
            store.copyImageToClipboard(image)
        }
    }

    private func copyAndPaste(_ content: ClipContent) {
        copyContent(content)

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
