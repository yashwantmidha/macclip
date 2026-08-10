import XCTest
@testable import macclip

final class AnnotationModelTests: XCTestCase {
    func testNormalizedRectFromAnyCorners() {
        let a = Annotation(kind: .rect, style: .default,
                           from: CGPoint(x: 100, y: 80), to: CGPoint(x: 20, y: 200))
        XCTAssertEqual(a.normalizedRect, CGRect(x: 20, y: 80, width: 80, height: 120))
    }

    func testFreehandBoundingBox() {
        let a = Annotation(kind: .freehand, style: .default,
                           points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 5), CGPoint(x: 30, y: 40)])
        XCTAssertEqual(a.boundingBox, CGRect(x: 10, y: 5, width: 40, height: 35))
    }

    func testTranslateMovesAllGeometry() {
        var a = Annotation(kind: .freehand, style: .default,
                           from: CGPoint(x: 1, y: 1), to: CGPoint(x: 2, y: 2),
                           points: [CGPoint(x: 3, y: 3)])
        a.translate(by: CGPoint(x: 10, y: -1))
        XCTAssertEqual(a.from, CGPoint(x: 11, y: 0))
        XCTAssertEqual(a.to, CGPoint(x: 12, y: 1))
        XCTAssertEqual(a.points, [CGPoint(x: 13, y: 2)])
    }

    func testDocumentCodableRoundTrip() throws {
        var doc = AnnotationDocument()
        doc.annotations = [
            Annotation(kind: .arrow, style: .default, from: .zero, to: CGPoint(x: 50, y: 50)),
            Annotation(kind: .text, style: .default, from: CGPoint(x: 5, y: 5), string: "note"),
            Annotation(kind: .badge, style: .default, from: CGPoint(x: 9, y: 9), number: 3)
        ]
        doc.cropRect = CGRect(x: 1, y: 2, width: 30, height: 40)
        doc.nextBadgeNumber = 4

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }

    func testCodableColorRoundTrip() {
        let color = CodableColor(.systemRed)
        let ns = color.nsColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(ns.redComponent, color.red, accuracy: 0.001)
        XCTAssertEqual(ns.alphaComponent, color.alpha, accuracy: 0.001)
    }
}
