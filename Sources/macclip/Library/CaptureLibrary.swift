import AppKit

struct CaptureRecord: Codable {
    let id: UUID
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    var edited: Bool
}

final class CaptureLibrary {
    static let shared = CaptureLibrary()

    static let defaultCap = 100
    var maxCaptures = defaultCap

    private(set) var records: [CaptureRecord] = []

    private let rootDir: URL
    private let capturesDir: URL
    private let thumbsDir: URL
    private let indexURL: URL
    private let io = DispatchQueue(label: "macclip.library.io")

    var onChange: (() -> Void)?

    init(rootDir: URL? = nil) {
        let base = rootDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacClip", isDirectory: true)
        self.rootDir = base
        self.capturesDir = base.appendingPathComponent("captures", isDirectory: true)
        self.thumbsDir = base.appendingPathComponent("thumbs", isDirectory: true)
        self.indexURL = base.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Paths

    func imageURL(_ id: UUID) -> URL {
        capturesDir.appendingPathComponent("\(id.uuidString).png")
    }

    func thumbnailURL(_ id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).png")
    }

    func annotationsURL(_ id: UUID) -> URL {
        capturesDir.appendingPathComponent("\(id.uuidString).annotations.json")
    }

    // MARK: - Queries

    func record(for id: UUID) -> CaptureRecord? {
        records.first(where: { $0.id == id })
    }

    func image(for id: UUID) -> NSImage? {
        NSImage(contentsOf: imageURL(id))
    }

    func thumbnail(for id: UUID) -> NSImage? {
        NSImage(contentsOf: thumbnailURL(id))
    }

    func document(for id: UUID) -> AnnotationDocument? {
        guard let data = try? Data(contentsOf: annotationsURL(id)) else {
            return nil
        }
        return try? JSONDecoder().decode(AnnotationDocument.self, from: data)
    }

    // MARK: - Mutations

    /// Moves a freshly captured temp file into the library. Returns the new record.
    @discardableResult
    func add(tempFile: URL) -> CaptureRecord? {
        guard let image = NSImage(contentsOf: tempFile),
              let rep = image.representations.first else {
            try? FileManager.default.removeItem(at: tempFile)
            return nil
        }

        let id = UUID()
        do {
            try FileManager.default.moveItem(at: tempFile, to: imageURL(id))
        } catch {
            return nil
        }

        let record = CaptureRecord(
            id: id,
            createdAt: Date(),
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            edited: false
        )
        records.insert(record, at: 0)
        writeThumbnail(for: id, from: image)
        evictIfNeeded()
        saveIndex()
        onChange?()
        return record
    }

    func markEdited(_ id: UUID, document: AnnotationDocument) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        let hasContent = !document.annotations.isEmpty || document.cropRect != nil
        records[idx].edited = hasContent

        if hasContent, let data = try? JSONEncoder().encode(document) {
            try? data.write(to: annotationsURL(id), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: annotationsURL(id))
        }
        saveIndex()
        onChange?()
    }

    /// Regenerates the thumbnail (e.g. after annotations change).
    func updateThumbnail(for id: UUID, with image: NSImage) {
        guard record(for: id) != nil else {
            return
        }
        writeThumbnail(for: id, from: image)
        onChange?()
    }

    func delete(_ id: UUID) {
        records.removeAll(where: { $0.id == id })
        for url in [imageURL(id), thumbnailURL(id), annotationsURL(id)] {
            try? FileManager.default.removeItem(at: url)
        }
        saveIndex()
        onChange?()
    }

    func clear() {
        let ids = records.map(\.id)
        records.removeAll()
        for id in ids {
            for url in [imageURL(id), thumbnailURL(id), annotationsURL(id)] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        saveIndex()
        onChange?()
    }

    func totalDiskBytes() -> Int64 {
        var total: Int64 = 0
        for record in records {
            let attrs = try? FileManager.default.attributesOfItem(atPath: imageURL(record.id).path)
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }

    // MARK: - Internals

    private func evictIfNeeded() {
        guard records.count > maxCaptures else {
            return
        }
        // Oldest-unedited first; edited captures only when nothing unedited remains.
        var toEvict = records.count - maxCaptures
        for record in records.reversed() where toEvict > 0 && !record.edited {
            delete(record.id)
            toEvict -= 1
        }
        for record in records.reversed() where toEvict > 0 {
            delete(record.id)
            toEvict -= 1
        }
    }

    private func writeThumbnail(for id: UUID, from image: NSImage) {
        let targetWidth: CGFloat = 320
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return
        }
        let scale = min(1, targetWidth / size.width)
        let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)

        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1)
        thumb.unlockFocus()

        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }
        let url = thumbnailURL(id)
        io.async {
            try? png.write(to: url, options: .atomic)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder().decode([CaptureRecord].self, from: data) else {
            return
        }
        // Drop records whose image file disappeared.
        records = decoded.filter { FileManager.default.fileExists(atPath: imageURL($0.id).path) }
    }

    private func saveIndex() {
        let snapshot = records
        let url = indexURL
        io.async {
            guard let data = try? Self.encoder().encode(snapshot) else {
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
