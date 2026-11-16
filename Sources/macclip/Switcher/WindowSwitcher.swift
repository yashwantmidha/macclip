import AppKit
import ApplicationServices

// Private but long-stable (used by AltTab, yabai, Rectangle). Maps AX window -> CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct SwitchableWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
}

/// Wraps `index + step` into `0..<count`.
func cycledIndex(_ index: Int, step: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((index + step) % count + count) % count
}

enum WindowEnumerator {
    /// Front-to-back on-screen windows of regular apps, excluding our own.
    static func onScreenWindows() -> [SwitchableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Without Screen Recording permission macOS strips window titles; keep untitled windows then.
        let hasTitles = CGPreflightScreenCaptureAccess()
        var apps: [pid_t: NSRunningApplication] = [:]

        return list.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                case let title = info[kCGWindowName as String] as? String ?? "",
                !title.isEmpty || !hasTitles,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50
            else { return nil }
            if (info[kCGWindowAlpha as String] as? Double ?? 1) <= 0 { return nil }

            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            apps[pid] = app
            guard let app, app.activationPolicy == .regular else { return nil }

            return SwitchableWindow(
                id: id,
                pid: pid,
                appName: app.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? ""),
                title: title,
                icon: app.icon
            )
        }
    }

    /// Minimized windows are not in the on-screen list; ask each app via Accessibility.
    static func minimizedWindows() -> [SwitchableWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [SwitchableWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.1) // a hung app must not stall the switcher
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for axWindow in axWindows {
                var minimized: CFTypeRef?
                var title: CFTypeRef?
                var id: CGWindowID = 0
                guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimized) == .success,
                      minimized as? Bool == true,
                      _AXUIElementGetWindow(axWindow, &id) == .success else { continue }
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
                result.append(SwitchableWindow(
                    id: id,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? "",
                    title: title as? String ?? "",
                    icon: app.icon
                ))
            }
        }
        return result
    }

    static func thumbnail(of window: SwitchableWindow) -> NSImage? {
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, window.id, [.boundsIgnoreFraming, .nominalResolution]
        ), cg.width > 1 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func axWindow(for window: SwitchableWindow) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        return axWindows.first { axWindow in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(axWindow, &id) == .success && id == window.id
        }
    }

    static func focus(_ window: SwitchableWindow) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate()

        guard let axWindow = axWindow(for: window) else { return }
        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    /// Presses the window's own close button, so the app still gets to ask about unsaved changes.
    static func close(_ window: SwitchableWindow) -> Bool {
        var button: CFTypeRef?
        guard let axWindow = axWindow(for: window),
              AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }
}

final class SwitcherPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onArrow: ((UInt16) -> Void)?
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 123...126: onArrow?(event.keyCode)
        case 13, 51, 117: onClose?() // W, Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

final class SwitcherGridView: NSView {
    // Layout mirrors AltTab's "medium" thumbnails style.
    static let windowPadding: CGFloat = 18
    static let edgeInsets: CGFloat = 12
    static let iconSize: CGFloat = 26
    static let thumb = NSSize(width: 240, height: 150)
    static let cell = NSSize(width: thumb.width + edgeInsets * 2,
                             height: edgeInsets + iconSize + 5 + thumb.height + edgeInsets)

    var windows: [SwitchableWindow] = []
    var thumbnails: [CGWindowID: NSImage] = [:]
    var selected = 0 {
        didSet {
            needsDisplay = true
            scrollToVisible(cellRect(selected).insetBy(dx: 0, dy: -Self.windowPadding))
        }
    }
    private(set) var columns = 1

    func layout(count: Int, maxWidth: CGFloat) -> NSSize {
        columns = max(1, min(count, Int((maxWidth - Self.windowPadding * 2) / Self.cell.width)))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        return NSSize(width: CGFloat(columns) * Self.cell.width + Self.windowPadding * 2,
                      height: CGFloat(rows) * Self.cell.height + Self.windowPadding * 2)
    }

    override var isFlipped: Bool { true }

    var onClick: ((Int) -> Void)?
    var onCloseClick: ((Int) -> Void)?
    static let closeSize: CGFloat = 20

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(x: Self.windowPadding + CGFloat(index % columns) * Self.cell.width,
               y: Self.windowPadding + CGFloat(index / columns) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let inner = cellRect(index).insetBy(dx: Self.edgeInsets, dy: Self.edgeInsets)
        return NSRect(x: inner.maxX - Self.closeSize, y: inner.minY + 3, width: Self.closeSize, height: Self.closeSize)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let x = p.x - Self.windowPadding, y = p.y - Self.windowPadding
        guard x >= 0, y >= 0 else { return }
        let col = Int(x / Self.cell.width), row = Int(y / Self.cell.height)
        let index = row * columns + col
        guard col < columns, windows.indices.contains(index) else { return }
        if closeRect(index).insetBy(dx: -4, dy: -4).contains(p) {
            onCloseClick?(index)
        } else {
            onClick?(index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85),
            .paragraphStyle: style
        ]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.gray.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3

        for (i, window) in windows.enumerated() {
            let cellRect = cellRect(i)

            if i == selected {
                let path = NSBezierPath(roundedRect: cellRect.insetBy(dx: 2.5, dy: 2.5), xRadius: 10, yRadius: 10)
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 3
                path.stroke()
            }

            let inner = cellRect.insetBy(dx: Self.edgeInsets, dy: Self.edgeInsets)
            let iconRect = NSRect(x: inner.minX, y: inner.minY, width: Self.iconSize, height: Self.iconSize)
            window.icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let title = window.title.isEmpty ? window.appName : window.title
            (title as NSString).draw(
                in: NSRect(x: iconRect.maxX + 6, y: inner.minY + 4,
                           width: inner.width - Self.iconSize - 6 - Self.closeSize - 6, height: 20),
                withAttributes: attrs)

            let close = closeRect(i)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: close).fill()
            let cross = NSBezierPath()
            let c = close.insetBy(dx: 6.5, dy: 6.5)
            cross.move(to: NSPoint(x: c.minX, y: c.minY)); cross.line(to: NSPoint(x: c.maxX, y: c.maxY))
            cross.move(to: NSPoint(x: c.maxX, y: c.minY)); cross.line(to: NSPoint(x: c.minX, y: c.maxY))
            cross.lineWidth = 1.5
            cross.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            cross.stroke()

            let thumbRect = NSRect(x: inner.minX, y: iconRect.maxY + 5, width: Self.thumb.width, height: Self.thumb.height)
            let image = thumbnails[window.id] ?? window.icon
            guard let image else { continue }
            let maxSize = thumbnails[window.id] == nil ? NSSize(width: 96, height: 96) : thumbRect.size
            let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let fit = NSRect(x: thumbRect.midX - size.width / 2, y: thumbRect.midY - size.height / 2,
                             width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Option+Tab window switcher modeled on Windows Alt+Tab: hotkey shows it with the
/// previous window selected, Tab / arrows cycle, releasing Option or clicking a
/// thumbnail switches, Escape cancels. Minimized windows are listed last.
final class WindowSwitcher {
    private var panel: SwitcherPanel?
    private let grid = SwitcherGridView()
    private let scroll = NSScrollView()
    private var releaseTimer: Timer?
    private var promptedAccessibility = false
    private var promptedScreenRecording = false

    var isShowing: Bool { panel?.isVisible == true }

    func step(_ delta: Int) {
        if isShowing {
            grid.selected = cycledIndex(grid.selected, step: delta, count: grid.windows.count)
            return
        }

        if !promptedScreenRecording && !CGPreflightScreenCaptureAccess() {
            promptedScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        let windows = WindowEnumerator.onScreenWindows() + WindowEnumerator.minimizedWindows()
        guard !windows.isEmpty else { return }
        grid.windows = windows
        grid.thumbnails = Dictionary(uniqueKeysWithValues: windows.compactMap { w in
            WindowEnumerator.thumbnail(of: w).map { (w.id, $0) }
        })
        grid.selected = cycledIndex(0, step: delta, count: windows.count)
        show()
    }

    private func show() {
        let screen = NSScreen.main
        let size = grid.layout(count: grid.windows.count, maxWidth: (screen?.frame.width ?? 1440) * 0.8)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // More rows than fit on screen: cap the panel and scroll the grid inside it.
        let visible = NSSize(width: size.width,
                             height: min(size.height, (screen?.visibleFrame.height ?? 900) * 0.85))
        panel.setContentSize(visible)
        scroll.frame = NSRect(origin: .zero, size: visible)
        grid.frame = NSRect(origin: .zero, size: size)
        grid.needsDisplay = true
        if let screen {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - visible.width / 2, y: f.midY - visible.height / 2))
        }
        let selected = grid.selected
        grid.selected = selected // re-run scroll-to-selection for the new layout
        panel.makeKeyAndOrderFront(nil)

        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { self?.commit() }
        }
        RunLoop.main.add(releaseTimer!, forMode: .common)
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onArrow = { [weak self] keyCode in self?.moveSelection(keyCode) }
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.closeWindow(at: self.grid.selected)
        }
        grid.onCloseClick = { [weak self] index in self?.closeWindow(at: index) }
        grid.onClick = { [weak self] index in
            self?.grid.selected = index
            self?.commit()
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 23
        effect.layer?.masksToBounds = true
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
        panel.contentView = effect
        return panel
    }

    /// Left/right wrap like Tab; up/down stay inside the grid.
    private func moveSelection(_ keyCode: UInt16) {
        let count = grid.windows.count
        switch keyCode {
        case 123: grid.selected = cycledIndex(grid.selected, step: -1, count: count)
        case 124: grid.selected = cycledIndex(grid.selected, step: 1, count: count)
        default:
            let next = grid.selected + (keyCode == 125 ? grid.columns : -grid.columns)
            if (0..<count).contains(next) { grid.selected = next }
        }
    }

    /// Closes a window and keeps the switcher open on the remaining ones.
    private func closeWindow(at index: Int) {
        guard grid.windows.indices.contains(index),
              WindowEnumerator.close(grid.windows[index]) else { return }
        grid.thumbnails[grid.windows[index].id] = nil
        grid.windows.remove(at: index)
        guard !grid.windows.isEmpty else { hide(); return }
        if index < grid.selected || grid.selected >= grid.windows.count {
            grid.selected = max(0, grid.selected - 1)
        }
        show()
    }

    private func commit() {
        guard isShowing, grid.windows.indices.contains(grid.selected) else { hide(); return }
        let target = grid.windows[grid.selected]
        hide()

        if !AXIsProcessTrusted() && !promptedAccessibility {
            promptedAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        WindowEnumerator.focus(target)
    }

    private func hide() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        panel?.orderOut(nil)
        grid.thumbnails = [:]
    }
}
