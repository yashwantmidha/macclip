import XCTest
@testable import macclip

final class CaptureLibraryTests: XCTestCase {
    private var tempRoot: URL!
    private var library: CaptureLibrary!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macclip-tests-\(UUID().uuidString)", isDirectory: true)
        library = CaptureLibrary(rootDir: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // lockFocus would inherit the display's 2x scale; build pixel-exact instead.
    private func makeTempPNG(width: Int = 64, height: Int = 48) -> URL {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let png = rep.representation(using: .png, properties: [:])!
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).png")
        try! png.write(to: url)
        return url
    }

    func testAddMovesFileAndCreatesRecord() {
        let temp = makeTempPNG(width: 64, height: 48)
        let record = library.add(tempFile: temp)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.pixelWidth, 64)
        XCTAssertEqual(record?.pixelHeight, 48)
        XCTAssertEqual(record?.edited, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "temp file must be moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(record!.id).path))
        XCTAssertNotNil(library.image(for: record!.id))
        XCTAssertEqual(library.records.count, 1)
    }

    func testAddInvalidFileReturnsNil() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bogus-\(UUID().uuidString).png")
        try! Data("not a png".utf8).write(to: bogus)
        XCTAssertNil(library.add(tempFile: bogus))
        XCTAssertTrue(library.records.isEmpty)
    }

    func testMarkEditedWritesAndClearsSidecar() {
        let record = library.add(tempFile: makeTempPNG())!
        var doc = AnnotationDocument()
        doc.annotations = [Annotation(kind: .rect, style: .default, from: .zero, to: CGPoint(x: 10, y: 10))]

        library.markEdited(record.id, document: doc)
        XCTAssertTrue(library.record(for: record.id)!.edited)
        XCTAssertEqual(library.document(for: record.id), doc)

        // Empty document clears the edited flag and sidecar.
        library.markEdited(record.id, document: AnnotationDocument())
        XCTAssertFalse(library.record(for: record.id)!.edited)
        XCTAssertNil(library.document(for: record.id))
    }

    func testDeleteRemovesEverything() {
        let record = library.add(tempFile: makeTempPNG())!
        library.delete(record.id)
        XCTAssertTrue(library.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(record.id).path))
    }

    func testClear() {
        _ = library.add(tempFile: makeTempPNG())
        _ = library.add(tempFile: makeTempPNG())
        library.clear()
        XCTAssertTrue(library.records.isEmpty)
    }

    func testEvictionDropsOldestUneditedFirst() {
        library.maxCaptures = 2
        let first = library.add(tempFile: makeTempPNG())!
        var doc = AnnotationDocument()
        doc.annotations = [Annotation(kind: .line, style: .default, from: .zero, to: CGPoint(x: 5, y: 5))]
        library.markEdited(first.id, document: doc)

        let second = library.add(tempFile: makeTempPNG())!
        let third = library.add(tempFile: makeTempPNG())!

        XCTAssertEqual(library.records.count, 2)
        XCTAssertNotNil(library.record(for: first.id), "edited capture survives eviction")
        XCTAssertNil(library.record(for: second.id), "oldest unedited evicted")
        XCTAssertNotNil(library.record(for: third.id))
    }

    func testIndexPersistsAcrossInstances() {
        let record = library.add(tempFile: makeTempPNG())!
        // index.json is written on a background queue; give it a beat.
        let deadline = Date().addingTimeInterval(2)
        var reloaded: CaptureLibrary!
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            reloaded = CaptureLibrary(rootDir: tempRoot)
        } while reloaded.records.isEmpty && Date() < deadline

        XCTAssertEqual(reloaded.records.map(\.id), [record.id])
        XCTAssertEqual(reloaded.records.first?.pixelWidth, 64)
    }
}
