#!/usr/bin/swift

import AppKit
import Foundation

enum IconGenerationError: Error {
    case missingBitmapRepresentation
    case iconutilFailed(Int32)
}

let appIconSetPath = CommandLine.arguments.dropFirst().first ?? "spk/Resources/Assets.xcassets/AppIcon.appiconset"
let icnsPath = CommandLine.arguments.dropFirst().dropFirst().first ?? "spk/Resources/AppIcon.icns"
let appIconSetURL = URL(fileURLWithPath: appIconSetPath, isDirectory: true)
let icnsURL = URL(fileURLWithPath: icnsPath)

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

try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

for icon in iconFiles {
    let image = makeIcon(size: icon.size)
    let destinationURL = appIconSetURL.appendingPathComponent(icon.name)
    try pngData(for: image).write(to: destinationURL)
}

try generateIcns(from: appIconSetURL, to: icnsURL)

func makeIcon(size: CGFloat) -> NSImage {
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let image = NSImage(size: canvas.size)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    drawBackground(size: size, canvas: canvas)
    drawWaveGlyph(size: size, canvas: canvas)

    return image
}

func drawBackground(size: CGFloat, canvas: NSRect) {
    let inset = size * 0.08
    let backgroundRect = canvas.insetBy(dx: inset, dy: inset)
    let backgroundPath = NSBezierPath(ovalIn: backgroundRect)
    NSColor(srgbRed: 0.88, green: 0.80, blue: 0.69, alpha: 1.0).setFill()
    backgroundPath.fill()
}

func drawWaveGlyph(size: CGFloat, canvas: NSRect) {
    let relativeHeights: [CGFloat] = [0.34, 0.58, 0.86, 0.58, 0.34]
    let glyphSide = size * 0.72
    let glyphRect = NSRect(
        x: canvas.midX - glyphSide / 2,
        y: canvas.midY - glyphSide / 2,
        width: glyphSide,
        height: glyphSide
    )
    let barWidth = max(glyphRect.width * 0.12, 1.5)
    let spacing = max(glyphRect.width * 0.07, 1.0)
    let totalWidth = CGFloat(relativeHeights.count) * barWidth + CGFloat(relativeHeights.count - 1) * spacing
    let startX = glyphRect.midX - totalWidth / 2

    NSColor(srgbRed: 0.23, green: 0.24, blue: 0.19, alpha: 1.0).setFill()

    for (index, relativeHeight) in relativeHeights.enumerated() {
        let barHeight = glyphRect.height * relativeHeight
        let x = startX + CGFloat(index) * (barWidth + spacing)
        let y = glyphRect.midY - barHeight / 2
        let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        capsule.fill()
    }
}

func pngData(for image: NSImage) throws -> Data {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.missingBitmapRepresentation
    }

    return png
}

func generateIcns(from appIconSetURL: URL, to icnsURL: URL) throws {
    let fileManager = FileManager.default
    let temporaryIconsetURL = fileManager.temporaryDirectory
        .appendingPathComponent("spk-\(UUID().uuidString).iconset", isDirectory: true)

    try fileManager.createDirectory(at: temporaryIconsetURL, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: temporaryIconsetURL)
    }

    let iconFiles = try fileManager.contentsOfDirectory(at: appIconSetURL, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "png" }

    for iconFile in iconFiles {
        let destinationURL = temporaryIconsetURL.appendingPathComponent(iconFile.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: iconFile, to: destinationURL)
    }

    if fileManager.fileExists(atPath: icnsURL.path) {
        try fileManager.removeItem(at: icnsURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", temporaryIconsetURL.path, "-o", icnsURL.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw IconGenerationError.iconutilFailed(process.terminationStatus)
    }
}
