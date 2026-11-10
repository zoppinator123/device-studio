// Renders the app icon into an .iconset directory: three mixer sliders on a dark tile.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Geometry on a 1024-point canvas, following the macOS icon grid:
// an 824-point tile, centered, leaving room for its shadow.
let canvas: CGFloat = 1024
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
let mint = NSColor(srgbRed: 0.42, green: 0.85, blue: 0.74, alpha: 1)
// Each slider: horizontal center and knob height.
let sliders: [(x: CGFloat, knob: CGFloat)] = [(336, 610), (512, 420), (688, 545)]
let track = (bottom: CGFloat(292), top: CGFloat(732), width: CGFloat(40))
let knobRadius: CGFloat = 62

func capsule(x: CGFloat, from bottom: CGFloat, to top: CGFloat) -> NSBezierPath {
    let rect = NSRect(x: x - track.width / 2, y: bottom, width: track.width, height: top - bottom)
    return NSBezierPath(roundedRect: rect, xRadius: track.width / 2, yRadius: track.width / 2)
}

func drawIcon() {
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(
        starting: NSColor(srgbRed: 0.13, green: 0.18, blue: 0.20, alpha: 1),
        ending: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)
    )!.draw(in: tilePath, angle: -90)

    for slider in sliders {
        mint.withAlphaComponent(0.22).setFill()
        capsule(x: slider.x, from: track.bottom, to: track.top).fill()
        mint.setFill()
        capsule(x: slider.x, from: track.bottom, to: slider.knob).fill()

        let knob = NSRect(x: slider.x - knobRadius, y: slider.knob - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        NSGraphicsContext.saveGraphicsState()
        let knobShadow = NSShadow()
        knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        knobShadow.shadowOffset = NSSize(width: 0, height: -6)
        knobShadow.shadowBlurRadius = 14
        knobShadow.set()
        NSColor(srgbRed: 0.96, green: 0.98, blue: 0.97, alpha: 1).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()

        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
