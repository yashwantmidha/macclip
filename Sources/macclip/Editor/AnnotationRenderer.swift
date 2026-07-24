import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws a document over its base image in *image pixel coordinates*
/// (bottom-left origin). The caller sets up any view/export transform, so the
/// live canvas and the flattened export share one code path.
enum AnnotationRenderer {

    static func drawBase(_ image: CGImage, in ctx: CGContext) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func draw(
        _ annotations: [Annotation],
        in ctx: CGContext,
        blurImage: (Annotation) -> CGImage?
    ) {
        for annotation in annotations {
            draw(annotation, in: ctx, blurImage: blurImage)
        }
    }

    static func draw(
        _ a: Annotation,
        in ctx: CGContext,
        blurImage: (Annotation) -> CGImage?
    ) {
        let color = a.style.color.nsColor
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(a.style.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .line:
            ctx.move(to: a.from)
            ctx.addLine(to: a.to)
            ctx.strokePath()

        case .arrow:
            drawArrow(a, in: ctx)

        case .rect:
            ctx.stroke(a.normalizedRect.insetBy(dx: a.style.strokeWidth / 2, dy: a.style.strokeWidth / 2))

        case .ellipse:
            ctx.strokeEllipse(in: a.normalizedRect.insetBy(dx: a.style.strokeWidth / 2, dy: a.style.strokeWidth / 2))

        case .freehand:
            guard let first = a.points.first else { break }
            ctx.move(to: first)
            for p in a.points.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()

        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(color.withAlphaComponent(0.4).cgColor)
            ctx.fill(a.normalizedRect)

        case .blur:
            let rect = a.normalizedRect
            if let img = blurImage(a) {
                ctx.draw(img, in: rect)
            } else {
                ctx.setFillColor(NSColor.systemGray.withAlphaComponent(0.6).cgColor)
                ctx.fill(rect)
            }

        case .text:
            let ns = a.string as NSString
            let size = ns.size(withAttributes: a.textAttributes)
            ns.draw(at: CGPoint(x: a.from.x, y: a.from.y - size.height), withAttributes: a.textAttributes)

        case .badge:
            let r = a.badgeRadius
            let circle = CGRect(x: a.from.x - r, y: a.from.y - r, width: r * 2, height: r * 2)
            ctx.fillEllipse(in: circle)
            let label = "\(a.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: r * 1.05),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: CGPoint(x: a.from.x - size.width / 2, y: a.from.y - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let dx = a.to.x - a.from.x
        let dy = a.to.y - a.from.y
        let length = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        let headLength = min(max(12, a.style.strokeWidth * 4.5), length * 0.4)
        let headAngle: CGFloat = .pi / 7

        // Shaft stops short of the tip so the head stays crisp.
        let shaftEnd = CGPoint(
            x: a.to.x - cos(angle) * headLength * 0.6,
            y: a.to.y - sin(angle) * headLength * 0.6
        )
        ctx.move(to: a.from)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let left = CGPoint(
            x: a.to.x - cos(angle - headAngle) * headLength,
            y: a.to.y - sin(angle - headAngle) * headLength
        )
        let right = CGPoint(
            x: a.to.x - cos(angle + headAngle) * headLength,
            y: a.to.y - sin(angle + headAngle) * headLength
        )
        ctx.move(to: a.to)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Blur helper

    static func pixellated(from base: CGImage, rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !clamped.isEmpty else {
            return nil
        }
        // CGImage cropping uses top-left origin; annotation rects are bottom-left.
        let cgRect = CGRect(
            x: clamped.origin.x,
            y: CGFloat(base.height) - clamped.maxY,
            width: clamped.width,
            height: clamped.height
        )
        guard let crop = base.cropping(to: cgRect) else {
            return nil
        }

        let input = CIImage(cgImage: crop)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(8, min(clamped.width, clamped.height) / 12))
        filter.center = CGPoint(x: clamped.width / 2, y: clamped.height / 2)

        guard let output = filter.outputImage else {
            return nil
        }
        let context = CIContext()
        return context.createCGImage(output, from: input.extent)
    }

    // MARK: - Flatten

    static func flatten(
        base: CGImage,
        document: AnnotationDocument,
        blurImage: (Annotation) -> CGImage?
    ) -> NSImage? {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let visible = document.cropRect ?? full
        let width = Int(visible.width)
        let height = Int(visible.height)
        guard width > 0, height > 0 else {
            return nil
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: width, height: height)

        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        ctx.translateBy(x: -visible.origin.x, y: -visible.origin.y)
        drawBase(base, in: ctx)
        draw(document.annotations, in: ctx, blurImage: blurImage)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
