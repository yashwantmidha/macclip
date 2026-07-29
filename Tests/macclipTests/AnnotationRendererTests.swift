import XCTest
@testable import macclip

final class AnnotationRendererTests: XCTestCase {
    // lockFocus-based helpers inherit the display's 2x scale; build pixel-exact instead.
    private func makeBaseImage(width: Int = 100, height: Int = 80) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testFlattenFullSizeMatchesBase() {
        let base = makeBaseImage(width: 100, height: 80)
        let flat = AnnotationRenderer.flatten(base: base, document: AnnotationDocument(), blurImage: { _ in nil })
        XCTAssertNotNil(flat)
        let rep = flat!.representations.first as! NSBitmapImageRep
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 80)
    }

    func testFlattenAppliesCrop() {
        let base = makeBaseImage(width: 100, height: 80)
        var doc = AnnotationDocument()
        doc.cropRect = CGRect(x: 10, y: 10, width: 40, height: 30)
        let flat = AnnotationRenderer.flatten(base: base, document: doc, blurImage: { _ in nil })
        let rep = flat!.representations.first as! NSBitmapImageRep
        XCTAssertEqual(rep.pixelsWide, 40)
        XCTAssertEqual(rep.pixelsHigh, 30)
    }

    func testFlattenDrawsAnnotationPixels() {
        let base = makeBaseImage(width: 100, height: 80)
        var doc = AnnotationDocument()
        var style = AnnotationStyle.default
        style.color = CodableColor(.black)
        style.strokeWidth = 10
        doc.annotations = [Annotation(kind: .line, style: style,
                                      from: CGPoint(x: 0, y: 40), to: CGPoint(x: 100, y: 40))]

        let flat = AnnotationRenderer.flatten(base: base, document: doc, blurImage: { _ in nil })!
        let rep = flat.representations.first as! NSBitmapImageRep
        // Midpoint of the thick black line must not be white anymore.
        // colorAt uses top-left origin; annotation y=40 (bottom-left) → row height-1-40.
        let mid = rep.colorAt(x: 50, y: 80 - 1 - 40)!
        XCTAssertLessThan(mid.brightnessComponent, 0.5)
    }

    func testPixellatedReturnsImageForValidRect() {
        let base = makeBaseImage()
        let result = AnnotationRenderer.pixellated(from: base, rect: CGRect(x: 10, y: 10, width: 30, height: 20))
        XCTAssertNotNil(result)
    }

    func testPixellatedReturnsNilForOutOfBoundsRect() {
        let base = makeBaseImage()
        let result = AnnotationRenderer.pixellated(from: base, rect: CGRect(x: 500, y: 500, width: 10, height: 10))
        XCTAssertNil(result)
    }

    func testPngDataProducesDecodableImage() {
        let base = makeBaseImage()
        let flat = AnnotationRenderer.flatten(base: base, document: AnnotationDocument(), blurImage: { _ in nil })!
        let png = AnnotationRenderer.pngData(flat)
        XCTAssertNotNil(png)
        XCTAssertNotNil(NSImage(data: png!))
    }
}
