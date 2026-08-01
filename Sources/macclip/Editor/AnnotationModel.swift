import AppKit

struct CodableColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        red = srgb.redComponent
        green = srgb.greenComponent
        blue = srgb.blueComponent
        alpha = srgb.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct AnnotationStyle: Codable, Equatable {
    var color: CodableColor
    var strokeWidth: CGFloat
    var fontSize: CGFloat

    static let `default` = AnnotationStyle(
        color: CodableColor(.systemRed),
        strokeWidth: 3.5,
        fontSize: 18
    )
}

enum AnnotationKind: String, Codable {
    case arrow, rect, ellipse, line, freehand, text, highlight, blur, badge
}

/// One annotation. A single struct with optional fields keeps Codable simple
/// and lets tools share move/hit-test logic.
struct Annotation: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    var style: AnnotationStyle

    /// arrow/line: endpoints. rect/ellipse/highlight/blur: bounding box corners.
    /// text/badge: `from` is the anchor point.
    var from: CGPoint
    var to: CGPoint
    var points: [CGPoint]   // freehand only
    var string: String      // text only
    var number: Int         // badge only

    init(kind: AnnotationKind,
         style: AnnotationStyle,
         from: CGPoint = .zero,
         to: CGPoint = .zero,
         points: [CGPoint] = [],
         string: String = "",
         number: Int = 0) {
        self.id = UUID()
        self.kind = kind
        self.style = style
        self.from = from
        self.to = to
        self.points = points
        self.string = string
        self.number = number
    }

    var boundingBox: CGRect {
        switch kind {
        case .arrow, .line:
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        case .rect, .ellipse, .highlight, .blur:
            return normalizedRect
        case .freehand:
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() {
                rect = rect.union(CGRect(origin: p, size: .zero))
            }
            return rect
        case .text:
            let size = (string as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: CGPoint(x: from.x, y: from.y - size.height), size: size)
        case .badge:
            let r = badgeRadius
            return CGRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)
        }
    }

    var normalizedRect: CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    var badgeRadius: CGFloat {
        max(14, style.fontSize * 0.8)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.boldSystemFont(ofSize: style.fontSize),
            .foregroundColor: style.color.nsColor
        ]
    }

    mutating func translate(by delta: CGPoint) {
        from = CGPoint(x: from.x + delta.x, y: from.y + delta.y)
        to = CGPoint(x: to.x + delta.x, y: to.y + delta.y)
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

struct AnnotationDocument: Codable, Equatable {
    var annotations: [Annotation] = []
    var cropRect: CGRect?
    var nextBadgeNumber: Int = 1
}
