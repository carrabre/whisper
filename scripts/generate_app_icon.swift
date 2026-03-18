#!/usr/bin/swift

import AppKit
import Foundation

enum IconGenerationError: Error {
    case missingBitmapRepresentation
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "WhisperType/Resources/Assets.xcassets/AppIcon.appiconset"
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)

let iconFiles: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_1024x1024.png", 1024),
]

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for icon in iconFiles {
    let image = makeIcon(size: icon.size)
    let destinationURL = outputURL.appendingPathComponent(icon.name)
    try pngData(for: image).write(to: destinationURL)
}

func makeIcon(size: CGFloat) -> NSImage {
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let image = NSImage(size: canvas.size)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = size * 0.035
    let iconRect = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = size * 0.225
    let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    iconPath.addClip()

    let baseGradient = NSGradient(colors: [
        NSColor(srgbRed: 0.19, green: 0.86, blue: 0.98, alpha: 1.0),
        NSColor(srgbRed: 0.08, green: 0.47, blue: 0.98, alpha: 1.0),
        NSColor(srgbRed: 0.04, green: 0.15, blue: 0.58, alpha: 1.0),
    ])!
    baseGradient.draw(in: iconPath, angle: -42)

    let topGlowPath = NSBezierPath(ovalIn: NSRect(
        x: iconRect.minX - size * 0.12,
        y: iconRect.midY + size * 0.06,
        width: size * 0.86,
        height: size * 0.62
    ))
    let topGlow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.26),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    topGlow.draw(in: topGlowPath, relativeCenterPosition: NSPoint(x: -0.25, y: 0.35))

    let bottomShadePath = NSBezierPath(rect: NSRect(
        x: iconRect.minX,
        y: iconRect.minY,
        width: iconRect.width,
        height: iconRect.height * 0.58
    ))
    let bottomShade = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.18),
    ])!
    bottomShade.draw(in: bottomShadePath, angle: 90)

    NSGraphicsContext.restoreGraphicsState()

    let rimPath = NSBezierPath(roundedRect: iconRect.insetBy(dx: size * 0.008, dy: size * 0.008), xRadius: cornerRadius * 0.94, yRadius: cornerRadius * 0.94)
    NSColor.white.withAlphaComponent(0.14).setStroke()
    rimPath.lineWidth = max(1, size * 0.015)
    rimPath.stroke()

    if size >= 64 {
        drawWave(on: .left, size: size, iconRect: iconRect)
        drawWave(on: .right, size: size, iconRect: iconRect)
    }

    drawMicrophone(size: size, iconRect: iconRect)

    return image
}

func drawMicrophone(size: CGFloat, iconRect: NSRect) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    let capsuleWidth = size * 0.18
    let capsuleHeight = size * 0.40
    let capsuleRect = NSRect(
        x: iconRect.midX - capsuleWidth / 2,
        y: iconRect.midY - capsuleHeight * 0.08,
        width: capsuleWidth,
        height: capsuleHeight
    )
    let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleWidth / 2, yRadius: capsuleWidth / 2)
    NSColor.white.withAlphaComponent(0.97).setFill()
    capsulePath.fill()

    let grillInset = size * 0.022
    let grillHeight = size * 0.018
    for index in 0..<3 {
        let grillRect = NSRect(
            x: capsuleRect.minX + grillInset,
            y: capsuleRect.midY + size * 0.055 - CGFloat(index) * size * 0.062,
            width: capsuleRect.width - grillInset * 2,
            height: grillHeight
        )
        let grillPath = NSBezierPath(roundedRect: grillRect, xRadius: grillHeight / 2, yRadius: grillHeight / 2)
        NSColor(srgbRed: 0.70, green: 0.87, blue: 1.0, alpha: 0.78).setFill()
        grillPath.fill()
    }

    let stemRect = NSRect(
        x: iconRect.midX - size * 0.028,
        y: capsuleRect.minY - size * 0.10,
        width: size * 0.056,
        height: size * 0.12
    )
    let stemPath = NSBezierPath(roundedRect: stemRect, xRadius: size * 0.028, yRadius: size * 0.028)
    NSColor.white.withAlphaComponent(0.92).setFill()
    stemPath.fill()

    let baseRect = NSRect(
        x: iconRect.midX - size * 0.15,
        y: stemRect.minY - size * 0.072,
        width: size * 0.30,
        height: size * 0.048
    )
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: size * 0.024, yRadius: size * 0.024)
    NSColor.white.withAlphaComponent(0.84).setFill()
    basePath.fill()

    NSGraphicsContext.restoreGraphicsState()
}

enum WaveSide {
    case left
    case right
}

func drawWave(on side: WaveSide, size: CGFloat, iconRect: NSRect) {
    let direction: CGFloat = side == .left ? -1 : 1
    let path = NSBezierPath()
    path.lineWidth = size * 0.042
    path.lineCapStyle = .round

    let start = NSPoint(
        x: iconRect.midX + direction * size * 0.165,
        y: iconRect.midY - size * 0.095
    )
    path.move(to: start)
    path.curve(
        to: NSPoint(
            x: iconRect.midX + direction * size * 0.235,
            y: iconRect.midY + size * 0.145
        ),
        controlPoint1: NSPoint(
            x: iconRect.midX + direction * size * 0.225,
            y: iconRect.midY - size * 0.01
        ),
        controlPoint2: NSPoint(
            x: iconRect.midX + direction * size * 0.29,
            y: iconRect.midY + size * 0.08
        )
    )

    NSColor.white.withAlphaComponent(0.26).setStroke()
    path.stroke()
}

func pngData(for image: NSImage) throws -> Data {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.missingBitmapRepresentation
    }

    return png
}
