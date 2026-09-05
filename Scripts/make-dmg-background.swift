#!/usr/bin/env swift
// Draws the Finder backdrop for the disk image: a white sheet with a handful
// of small Dukou bubbles — the app icon's mark — scattered around the two big
// icons Finder itself draws. No source artwork and no text: the picture is a
// few shapes, generating it keeps a binary nobody can diff out of the review,
// and the one instruction a drag-to-install window needs is the layout itself.
//
// The canvas is 1320 x 800 pixels presented as 660 x 400 points, so the image
// is a 2x asset and stays sharp on Retina displays. Finder reads the point size
// from the PNG's DPI, which `bitmap.size` writes.
//
//   swift Scripts/make-dmg-background.swift Resources/DMG/background.png
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: make-dmg-background.swift <output.png>\n", stderr)
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])
let pointSize = NSSize(width: 660, height: 400)
let scale = 2

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pointSize.width) * scale,
    pixelsHigh: Int(pointSize.height) * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("cannot create the disk image canvas\n", stderr)
    exit(1)
}
// Declared before the context is derived, otherwise one unit maps to one
// pixel and every coordinate below lands at half scale.
bitmap.size = pointSize

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("cannot create the disk image drawing context\n", stderr)
    exit(1)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// One sticker: the app icon's bubble at a size and tilt of its own.
struct Sticker {
    let fill: NSColor
    /// Centre in points, measured from the top-left of the image.
    let center: NSPoint
    let scale: CGFloat
    /// Positive tilts clockwise on screen.
    let rotation: CGFloat
}

/// Around the two icon slots — Dukou.app at (178, 226) and Applications at
/// (482, 226) in make-dmg.sh, 112 pt each plus a label — and never on the
/// line between them: that lane is where the drag happens.
let stickers = [
    Sticker(fill: color(0x21A075), center: NSPoint(x: 92, y: 66), scale: 1.0, rotation: -10),
    Sticker(fill: color(0x3DC08F), center: NSPoint(x: 362, y: 50), scale: 0.9, rotation: 8),
    Sticker(fill: color(0x0F9488), center: NSPoint(x: 574, y: 80), scale: 1.1, rotation: -12),
    Sticker(fill: color(0x5FCDA3), center: NSPoint(x: 296, y: 126), scale: 0.72, rotation: -6),
    Sticker(fill: color(0x1B8A66), center: NSPoint(x: 64, y: 330), scale: 0.9, rotation: 12),
    Sticker(fill: color(0x21A075), center: NSPoint(x: 330, y: 342), scale: 1.0, rotation: -5),
    Sticker(fill: color(0x3DC08F), center: NSPoint(x: 598, y: 328), scale: 0.85, rotation: 10),
]

/// The icon's bubble: a wide ellipse with a nub of a tail at the lower right.
/// Two shapes filled in the same colour rather than one outline, because
/// nothing here is stroked and a seam only shows on a stroke.
func bubbleShapes() -> [NSBezierPath] {
    let body = NSBezierPath(ovalIn: NSRect(x: -23, y: -16, width: 46, height: 32))
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 6, y: -12))
    tail.curve(
        to: NSPoint(x: 24, y: -21),
        controlPoint1: NSPoint(x: 13, y: -17),
        controlPoint2: NSPoint(x: 20, y: -21)
    )
    tail.curve(
        to: NSPoint(x: 19, y: -7),
        controlPoint1: NSPoint(x: 27, y: -16),
        controlPoint2: NSPoint(x: 24, y: -9)
    )
    tail.close()
    return [body, tail]
}

func fill(_ shapes: [NSBezierPath], with color: NSColor, dy: CGFloat = 0) {
    color.setFill()
    for shape in shapes {
        let copy = shape.copy() as! NSBezierPath
        copy.transform(using: AffineTransform(translationByX: 0, byY: dy))
        copy.fill()
    }
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

NSColor.white.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: pointSize)).fill()

for sticker in stickers {
    NSGraphicsContext.saveGraphicsState()

    let transform = NSAffineTransform()
    // The table gives centres from the top-left; the drawing space grows upward.
    transform.translateX(by: sticker.center.x, yBy: pointSize.height - sticker.center.y)
    transform.rotate(byDegrees: -sticker.rotation)
    transform.scale(by: sticker.scale)
    transform.concat()

    let shapes = bubbleShapes()
    // The icon's shaded underside: the same shape a little lower, in a darker
    // cut of the fill. Drawn in one transparency layer so the shadow belongs
    // to the whole sticker rather than to each of its shapes.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    let underside = sticker.fill.blended(withFraction: 0.28, of: .black) ?? sticker.fill
    fill(shapes, with: underside, dy: -2.5)
    fill(shapes, with: sticker.fill)
    context.cgContext.endTransparencyLayer()

    NSShadow().set()
    NSColor.white.setFill()
    let dotDiameter: CGFloat = 4.8
    for offset in [CGFloat(-5.8), 5.8] {
        NSBezierPath(ovalIn: NSRect(
            x: offset - dotDiameter / 2,
            y: 1 - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("cannot encode the disk image background\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
print("wrote \(outputURL.path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px, \(Int(pointSize.width))x\(Int(pointSize.height)) pt)")
