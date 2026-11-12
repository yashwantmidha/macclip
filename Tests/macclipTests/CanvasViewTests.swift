import XCTest
@testable import macclip

/// Drives CanvasView with synthesized mouse/key events (no window needed).
final class CanvasViewTests: XCTestCase {
    // 200x200 image in a 232x232 view => scale 1, offset 16: view = image + 16.
    private func makeCanvas() -> CanvasView {
        let size = 200
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Four differently colored quadrants so pixelation differs by position.
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: (i % 2) * 100, y: (i / 2) * 100, width: 100, height: 100))
        }
        let canvas = CanvasView(baseImage: ctx.makeImage()!, document: AnnotationDocument())
        canvas.frame = NSRect(x: 0, y: 0, width: 232, height: 232)
        return canvas
    }

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x + 16, y: y + 16), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func drag(_ canvas: CanvasView, from a: CGPoint, to b: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, a.x, a.y))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, b.x, b.y))
        canvas.mouseUp(with: mouse(.leftMouseUp, b.x, b.y))
        RunLoop.current.run(until: Date()) // close the per-event undo group
    }

    private func key(_ canvas: CanvasView, _ code: UInt16) {
        canvas.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        )!)
        RunLoop.current.run(until: Date())
    }

    private func bytes(_ image: CGImage?) -> Data? {
        image?.dataProvider?.data as Data?
    }

    func testDrawUndoRedo() {
        let canvas = makeCanvas()
        canvas.tool = .rect
        drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 60))
        XCTAssertEqual(canvas.document.annotations.count, 1)
        XCTAssertEqual(canvas.document.annotations[0].normalizedRect, CGRect(x: 20, y: 20, width: 60, height: 40))

        canvas.undoManager?.undo()
        XCTAssertTrue(canvas.document.annotations.isEmpty)
        canvas.undoManager?.redo()
        XCTAssertEqual(canvas.document.annotations.count, 1)
    }

    func testTinyDragIsIgnored() {
        let canvas = makeCanvas()
        canvas.tool = .arrow
        drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 21, y: 21))
        XCTAssertTrue(canvas.document.annotations.isEmpty)
    }

    func testBlurCacheFollowsUndoOfMove() {
        let canvas = makeCanvas()
        canvas.tool = .blur
        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        let blur = canvas.document.annotations[0]
        let original = bytes(canvas.currentBlurImage(for: blur))
        XCTAssertNotNil(original)

        canvas.tool = .select
        drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 130, y: 130))
        XCTAssertEqual(canvas.document.annotations[0].normalizedRect.origin, CGPoint(x: 110, y: 110))
        XCTAssertNotEqual(bytes(canvas.currentBlurImage(for: blur)), original)

        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.document.annotations[0].normalizedRect.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(bytes(canvas.currentBlurImage(for: blur)), original)
    }

    func testCropApplyThenEscapeResets() {
        let canvas = makeCanvas()
        canvas.tool = .crop
        drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 120))
        XCTAssertNil(canvas.document.cropRect)
        key(canvas, 36) // return applies
        XCTAssertEqual(canvas.document.cropRect, CGRect(x: 20, y: 20, width: 100, height: 100))
        key(canvas, 53) // escape resets
        XCTAssertNil(canvas.document.cropRect)
    }

    func testBadgesNumberSequentially() {
        let canvas = makeCanvas()
        canvas.tool = .badge
        canvas.mouseDown(with: mouse(.leftMouseDown, 50, 50))
        canvas.mouseDown(with: mouse(.leftMouseDown, 90, 90))
        XCTAssertEqual(canvas.document.annotations.map(\.number), [1, 2])
    }

    func testDeleteSelection() {
        let canvas = makeCanvas()
        canvas.tool = .rect
        drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 60))
        canvas.tool = .select
        canvas.mouseDown(with: mouse(.leftMouseDown, 50, 40))
        canvas.mouseUp(with: mouse(.leftMouseUp, 50, 40))
        XCTAssertNotNil(canvas.selectedID)
        key(canvas, 51) // delete
        XCTAssertTrue(canvas.document.annotations.isEmpty)
    }
}
