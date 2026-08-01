import AppKit

final class LibraryWindowController: NSWindowController, NSWindowDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {

    private struct DayGroup {
        let title: String
        var records: [CaptureRecord]
    }

    private let library: CaptureLibrary
    private let onEdit: (UUID) -> Void
    private var groups: [DayGroup] = []
    private var collectionView: LibraryCollectionView!
    private let searchField = NSSearchField()

    init(library: CaptureLibrary, onEdit: @escaping (UUID) -> Void) {
        self.library = library
        self.onEdit = onEdit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)

        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        buildUI()

        library.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else {
            return
        }

        let clearButton = NSButton(title: "Clear Library…", target: self, action: #selector(clearPressed))
        clearButton.bezelStyle = .rounded

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let toolbar = NSStackView(views: [clearButton, NSView(), searchField])
        toolbar.orientation = .horizontal
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 168, height: 138)
        layout.sectionInset = NSEdgeInsets(top: 4, left: 16, bottom: 18, right: 16)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 14
        layout.headerReferenceSize = NSSize(width: 0, height: 28)

        collectionView = LibraryCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(LibraryItem.self, forItemWithIdentifier: LibraryItem.identifier)
        collectionView.register(
            LibraryHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: LibraryHeader.identifier
        )
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let record = self?.record(at: indexPath) else { return }
            self?.onEdit(record.id)
        }
        collectionView.onContextMenu = { [weak self] indexPath in
            self?.contextMenu(for: indexPath)
        }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(separator)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    // MARK: - Data

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var filtered = library.records
        if !query.isEmpty {
            let dayFormatter = DateFormatter()
            dayFormatter.dateStyle = .medium
            filtered = filtered.filter { record in
                let dims = "\(record.pixelWidth)x\(record.pixelHeight)"
                let day = dayFormatter.string(from: record.createdAt).lowercased()
                return dims.contains(query) || day.contains(query)
                    || (record.edited && "edited".contains(query))
            }
        }

        var grouped: [DayGroup] = []
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .medium
        for record in filtered {
            let title: String
            if calendar.isDateInToday(record.createdAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(record.createdAt) {
                title = "Yesterday"
            } else {
                title = dayFormatter.string(from: record.createdAt)
            }
            if grouped.last?.title == title {
                grouped[grouped.count - 1].records.append(record)
            } else {
                grouped.append(DayGroup(title: title, records: [record]))
            }
        }
        groups = grouped

        let count = library.records.count
        let mb = Double(library.totalDiskBytes()) / 1_048_576
        window?.title = count == 0
            ? "Library — empty"
            : String(format: "Library — %d capture%@ · %.0f MB", count, count == 1 ? "" : "s", mb)
        collectionView.reloadData()
    }

    private func record(at indexPath: IndexPath) -> CaptureRecord? {
        guard indexPath.section < groups.count,
              indexPath.item < groups[indexPath.section].records.count else {
            return nil
        }
        return groups[indexPath.section].records[indexPath.item]
    }

    // MARK: - Context menu

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard let record = record(at: indexPath) else {
            return nil
        }
        let id = record.id
        let menu = NSMenu()
        menu.addItem(makeItem("Edit") { [weak self] in self?.onEdit(id) })
        menu.addItem(makeItem("Copy Image") { [weak self] in
            guard let image = self?.library.image(for: id) else { return }
            NSPasteboard.general.setImageAllFlavors(image)
        })
        menu.addItem(makeItem("Save As…") { [weak self] in self?.saveAs(id) })
        menu.addItem(makeItem("Reveal in Finder") { [weak self] in
            guard let url = self?.library.imageURL(id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(.separator())
        menu.addItem(makeItem("Delete") { [weak self] in self?.library.delete(id) })
        return menu
    }

    private func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = BlockMenuItem(title: title, action: action)
        return item
    }

    private func saveAs(_ id: UUID) {
        guard let window, let record = library.record(for: id) else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Capture \(formatter.string(from: record.createdAt)).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            try? FileManager.default.copyItem(at: self.library.imageURL(id), to: url)
        }
    }

    @objc private func clearPressed() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the capture library?"
        alert.informativeText = "All \(library.records.count) captures and their annotations will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Library")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.library.clear()
            }
        }
    }

    // MARK: - NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        groups.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].records.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryItem.identifier, for: indexPath)
        if let item = item as? LibraryItem, let record = record(at: indexPath) {
            item.configure(record: record, thumbnail: library.thumbnail(for: record.id) ?? library.image(for: record.id))
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: LibraryHeader.identifier,
            for: indexPath
        )
        if let header = view as? LibraryHeader, indexPath.section < groups.count {
            header.label.stringValue = groups[indexPath.section].title.uppercased()
        }
        return view
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
}

// MARK: - Collection view plumbing

final class LibraryCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var onContextMenu: ((IndexPath) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            onDoubleClick?(indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            return super.menu(for: event)
        }
        selectionIndexPaths = [indexPath]
        return onContextMenu?(indexPath) ?? super.menu(for: event)
    }
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.block = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        block()
    }
}

final class LibraryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryItem")

    private let thumbView = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let dimsLabel = NSTextField(labelWithString: "")
    private let editedDot = NSView()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 1
        thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = NSFont.systemFont(ofSize: 11)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        dimsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimsLabel.textColor = .secondaryLabelColor
        dimsLabel.translatesAutoresizingMaskIntoConstraints = false

        editedDot.wantsLayer = true
        editedDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        editedDot.layer?.cornerRadius = 4
        editedDot.layer?.borderWidth = 1.5
        editedDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        editedDot.translatesAutoresizingMaskIntoConstraints = false
        editedDot.isHidden = true

        view.addSubview(thumbView)
        view.addSubview(timeLabel)
        view.addSubview(dimsLabel)
        view.addSubview(editedDot)

        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbView.heightAnchor.constraint(equalToConstant: 105),

            timeLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 5),
            timeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),

            dimsLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 5),
            dimsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),

            editedDot.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 7),
            editedDot.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -7),
            editedDot.widthAnchor.constraint(equalToConstant: 8),
            editedDot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    func configure(record: CaptureRecord, thumbnail: NSImage?) {
        thumbView.image = thumbnail
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.stringValue = formatter.string(from: record.createdAt)
        dimsLabel.stringValue = "\(record.pixelWidth)×\(record.pixelHeight)"
        editedDot.isHidden = !record.edited
    }

    override var isSelected: Bool {
        didSet {
            thumbView.layer?.borderWidth = isSelected ? 3 : 1
            thumbView.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
        }
    }
}

final class LibraryHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryHeader")

    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
