// Renders the MacClip app icon: white scissors glyph on a blue gradient
// squircle. Usage: swift scripts/make_icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: swift make_icon.swift <out.png> [size]")
    exit(1)
}
let outPath = args[1]
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024

let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let s = CGFloat(size)
let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = graphics

// macOS icons float inside ~10% transparent margin.
let inset = s * 0.10
let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.16, green: 0.47, blue: 0.96, alpha: 1),
    ending: NSColor(srgbRed: 0.36, green: 0.20, blue: 0.86, alpha: 1)
)!
gradient.draw(in: squircle, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .medium)
if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let drawSize = NSSize(width: rect.width * 0.58, height: rect.width * 0.58 * symbol.size.height / symbol.size.width)
    let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    tinted.draw(in: NSRect(origin: origin, size: drawSize))
}

NSGraphicsContext.current = nil
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)x\(size))")
