#!/usr/bin/env swift
// Draws the Finder backdrop for the disk image: a white sheet with six Dukou
// stickers — the app icon's bubble, each with a small pointer beside it —
// placed exactly where the reference installer (Grok Bot, 2026-09-06) puts
// its mascot stickers. Positions, colours and pointer headings are measured
// from that reference and mapped onto this window; only the mascot is ours.
// The lane between the two big icons stays empty because that is where the
// drag happens.
//
// No source artwork and no text: the picture is a few shapes, generating it
// keeps a binary nobody can diff out of the review.
//
// The canvas is 1320 x 800 pixels presented as 660 x 400 points, so the image
// is a 2x asset and stays sharp on Retina displays. Finder reads the point size
// from the PNG's DPI, which `bitmap.size` writes. Only the top 372 pt are ever
// seen: make-dmg.sh sizes the window 660 x 400 including its title bar.
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

/// One sticker: the bubble where the reference has its mascot's face, and a
/// pointer beside it on the reference's heading.
struct Sticker {
    let fill: NSColor
    /// Bubble centre in points, measured from the top-left of the image.
    let center: NSPoint
    /// Pointer centre relative to the bubble centre, in points.
    let pointerOffset: NSPoint
    /// Where the pointer's tip points, in degrees: 0 = right, 90 = down.
    let heading: CGFloat
}

/// Measured on the reference (760 x 500 pt window, icons centred at
/// x = 225 / 525, y = 230) and scaled uniformly onto this one (660 x 372 pt
/// visible: x × 0.868, y × 0.744). make-dmg.sh places the icons with the same
/// factors — (195, 176) and (456, 176) — so the whole window is the reference
/// at 87 % width, stickers and icons alike. Pointer offsets are scaled once
/// (0.87) so each pair keeps its shape.
let stickers = [
    Sticker(fill: color(0xFE2A3F), center: NSPoint(x: 429, y: 32), pointerOffset: NSPoint(x: 2.6, y: 21.8), heading: 84),
    Sticker(fill: color(0x93643A), center: NSPoint(x: 304, y: 80), pointerOffset: NSPoint(x: 19.6, y: 11.3), heading: 21),
    Sticker(fill: color(0x07BDA8), center: NSPoint(x: 595, y: 79), pointerOffset: NSPoint(x: -14.8, y: 16.1), heading: 129),
    Sticker(fill: color(0x1586FD), center: NSPoint(x: 593, y: 283), pointerOffset: NSPoint(x: -16.1, y: -17.4), heading: -133),
    Sticker(fill: color(0x925BFD), center: NSPoint(x: 303, y: 257), pointerOffset: NSPoint(x: 18.7, y: -10.9), heading: -30),
    Sticker(fill: color(0xFE6A06), center: NSPoint(x: 405, y: 340), pointerOffset: NSPoint(x: 7, y: -19.6), heading: -75),
]
/// The reference's faces are 24 pt across; the bubble body is 46 pt wide at
/// scale 1, so it is drawn at a little over half size.
let bubbleScale: CGFloat = 0.55
/// The reference's pointers are nearly as big as its faces.
let pointerScale: CGFloat = 0.9
/// The bubble has a tail the reference's round face does not, so each pointer
/// sits a little further out than measured or the two touch.
let pointerOffsetScale: CGFloat = 1.15

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

/// The reference's pointer: a triangle with a notch cut into its base, tip on
/// +x — the shape of a cursor, which is what it is standing in for.
func pointerShape() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 15, y: 0))
    path.line(to: NSPoint(x: -11, y: 10))
    path.line(to: NSPoint(x: -5, y: 0))
    path.line(to: NSPoint(x: -11, y: -10))
    path.close()
    return path
}

func fill(_ shapes: [NSBezierPath], with color: NSColor, dy: CGFloat = 0) {
    color.setFill()
    for shape in shapes {
        let copy = shape.copy() as! NSBezierPath
        copy.transform(using: AffineTransform(translationByX: 0, byY: dy))
        copy.fill()
    }
}

/// Fills `shapes` as one sticker: the icon's shaded underside first (the same
/// shape a little lower, in a darker cut of the fill), then the face, in a
/// single transparency layer so the drop shadow belongs to the whole sticker
/// rather than to each of its parts.
func drawSticker(_ shapes: [NSBezierPath], fill color: NSColor) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    let underside = color.blended(withFraction: 0.28, of: .black) ?? color
    fill(shapes, with: underside, dy: -2.5)
    fill(shapes, with: color)
    context.cgContext.endTransparencyLayer()
    NSShadow().set()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

NSColor.white.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: pointSize)).fill()

for sticker in stickers {
    // Bubble, upright: the reference's faces are not tilted.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    // The table gives centres from the top-left; the drawing space grows upward.
    transform.translateX(by: sticker.center.x, yBy: pointSize.height - sticker.center.y)
    transform.scale(by: bubbleScale)
    transform.concat()
    drawSticker(bubbleShapes(), fill: sticker.fill)
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

    // Pointer, in a lighter cut of the same colour as on the reference, turned
    // onto its heading. A top-left heading is mirrored in the upward-growing
    // drawing space, hence the sign.
    NSGraphicsContext.saveGraphicsState()
    let pointerTransform = NSAffineTransform()
    pointerTransform.translateX(
        by: sticker.center.x + sticker.pointerOffset.x * pointerOffsetScale,
        yBy: pointSize.height - (sticker.center.y + sticker.pointerOffset.y * pointerOffsetScale)
    )
    pointerTransform.rotate(byDegrees: -sticker.heading)
    pointerTransform.scale(by: pointerScale)
    pointerTransform.concat()
    let lighter = sticker.fill.blended(withFraction: 0.2, of: .white) ?? sticker.fill
    drawSticker([pointerShape()], fill: lighter)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("cannot encode the disk image background\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
print("wrote \(outputURL.path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px, \(Int(pointSize.width))x\(Int(pointSize.height)) pt)")
