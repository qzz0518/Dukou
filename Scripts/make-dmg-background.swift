#!/usr/bin/env swift
// Turns the reviewed DMG artwork into the 660×400 Finder background the
// release image opens with, adding the one thing the artwork must not carry:
// the instruction text, which has to stay editable without repainting.
//
// The artwork (Resources/DMG/background-source.png) is drawn at 2x and
// already keeps the two icon slots and their label plates calm; only the
// title band at the top is filled in here.
//
//   swift Scripts/make-dmg-background.swift Resources/DMG/background-source.png Resources/DMG/background.png
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: make-dmg-background.swift <source.png> <output.png>\n", stderr)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("cannot read \(sourceURL.path)\n", stderr)
    exit(1)
}

let size = NSSize(width: 660, height: 400)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("cannot create DMG background canvas\n", stderr)
    exit(1)
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Aspect-fill, centred: the artwork is drawn 660×400 already, so this only
// ever matters if it is regenerated at another size.
let targetAspect = size.width / size.height
let sourceAspect = source.size.width / source.size.height
let sourceRect: NSRect
if sourceAspect > targetAspect {
    let width = source.size.height * targetAspect
    sourceRect = NSRect(x: (source.size.width - width) / 2, y: 0, width: width, height: source.size.height)
} else {
    let height = source.size.width / targetAspect
    sourceRect = NSRect(x: 0, y: (source.size.height - height) / 2, width: source.size.width, height: height)
}
source.draw(in: NSRect(origin: .zero, size: size), from: sourceRect, operation: .copy, fraction: 1)

let centered = NSMutableParagraphStyle()
centered.alignment = .center

"拖动安装  ·  Drag to install".draw(
    in: NSRect(x: 40, y: 329, width: 580, height: 30),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
        .paragraphStyle: centered,
        .kern: 0.2,
    ]
)
"将 Dukou 拖到 Applications 文件夹".draw(
    in: NSRect(x: 40, y: 306, width: 580, height: 20),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.66, alpha: 1),
        .paragraphStyle: centered,
        .kern: 0.1,
    ]
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("cannot encode DMG background\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
print("wrote \(outputURL.path) (\(Int(size.width))x\(Int(size.height)))")
