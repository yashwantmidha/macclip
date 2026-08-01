import XCTest
@testable import macclip

final class PreviewTextTests: XCTestCase {
    func testShortTextUnchanged() {
        XCTAssertEqual(previewText("hello"), "hello")
    }

    func testNewlinesCollapsed() {
        XCTAssertEqual(previewText("a\nb\nc"), "a b c")
    }

    func testLongTextTruncatedWithEllipsis() {
        let long = String(repeating: "x", count: 300)
        let result = previewText(long, limit: 120)
        XCTAssertEqual(result.count, 120)
        XCTAssertTrue(result.hasSuffix("…"))
    }
}

final class ClipboardStoreTests: XCTestCase {
    func testAddCaptureInsertsAtTop() {
        let store = ClipboardStore(maxItems: 10)
        let a = UUID(), b = UUID()
        store.addCapture(a)
        store.addCapture(b)
        XCTAssertEqual(store.items.map(\.content), [.capture(b), .capture(a)])
    }

    func testDuplicateCaptureMovesToTopWithoutDuplicating() {
        let store = ClipboardStore(maxItems: 10)
        let a = UUID(), b = UUID()
        store.addCapture(a)
        store.addCapture(b)
        store.addCapture(a)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.content, .capture(a))
    }

    func testPinnedItemsStayOnTopAndSurvivePush() {
        let store = ClipboardStore(maxItems: 10)
        let a = UUID(), b = UUID()
        store.addCapture(a)
        store.addCapture(b)
        XCTAssertTrue(store.togglePin(content: .capture(a)))
        XCTAssertEqual(store.items.first?.content, .capture(a))

        // Re-pushing a pinned item keeps its pin.
        store.addCapture(a)
        XCTAssertTrue(store.items.first?.pinned ?? false)
    }

    func testTrimEvictsUnpinnedFirst() {
        let store = ClipboardStore(maxItems: 10)
        let ids = (0..<4).map { _ in UUID() }
        ids.forEach { store.addCapture($0) }
        _ = store.togglePin(content: .capture(ids[0])) // oldest, pinned

        store.setMaxItems(2)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.contains(where: { $0.content == .capture(ids[0]) }),
                      "pinned oldest must survive trim")
        XCTAssertTrue(store.items.contains(where: { $0.content == .capture(ids[3]) }),
                      "newest unpinned must survive trim")
    }

    func testRemoveCapturesNotInValidSet() {
        let store = ClipboardStore(maxItems: 10)
        let keep = UUID(), drop = UUID()
        store.addCapture(keep)
        store.addCapture(drop)
        store.removeCaptures(notIn: [keep])
        XCTAssertEqual(store.items.map(\.content), [.capture(keep)])
    }

    func testRemove() {
        let store = ClipboardStore(maxItems: 10)
        let a = UUID()
        store.addCapture(a)
        XCTAssertTrue(store.remove(content: .capture(a)))
        XCTAssertFalse(store.remove(content: .capture(a)))
        XCTAssertTrue(store.items.isEmpty)
    }
}
