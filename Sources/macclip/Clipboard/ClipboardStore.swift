import AppKit

func previewText(_ text: String, limit: Int = 120) -> String {
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

extension NSPasteboard {
    /// Writes PNG + TIFF flavors so browsers, chat apps, and editors all accept the paste.
    func setImageAllFlavors(_ image: NSImage) {
        clearContents()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            declareTypes([.png, .tiff], owner: nil)
            setData(png, forType: .png)
            setData(tiff, forType: .tiff)
        } else {
            writeObjects([image])
        }
    }
}

enum ClipContent: Equatable {
    case text(String)
    case capture(UUID)
}

struct ClipItem {
    let content: ClipContent
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
        push(.text(text))
    }

    func addCapture(_ id: UUID) {
        push(.capture(id))
    }

    /// Drops history rows for captures that no longer exist in the library.
    func removeCaptures(notIn validIDs: Set<UUID>) {
        items.removeAll { item in
            if case .capture(let id) = item.content {
                return !validIDs.contains(id)
            }
            return false
        }
    }

    private func push(_ content: ClipContent) {
        if items.first?.content == content {
            return
        }

        var wasPinned = false
        if let idx = items.firstIndex(where: { $0.content == content }) {
            wasPinned = items[idx].pinned
            items.remove(at: idx)
        }

        let item = ClipItem(content: content, pinned: wasPinned)
        if item.pinned {
            items.insert(item, at: 0)
        } else {
            items.insert(item, at: firstUnpinnedIndex())
        }

        trimToLimit()
    }

    @discardableResult
    func togglePin(content: ClipContent) -> Bool {
        guard let idx = items.firstIndex(where: { $0.content == content }) else {
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
    func remove(content: ClipContent) -> Bool {
        guard let idx = items.firstIndex(where: { $0.content == content }) else {
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

    func copyImageToClipboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.setImageAllFlavors(image)
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
