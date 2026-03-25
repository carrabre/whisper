import AppKit
import SwiftUI

private enum SpkLogoMetrics {
    static let relativeHeights: [CGFloat] = [0.34, 0.58, 0.86, 0.58, 0.34]
}

struct SpkWaveGlyph: View {
    var foregroundStyle: Color = .white

    private let relativeHeights = SpkLogoMetrics.relativeHeights

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let barWidth = max(width * 0.12, 2)
            let spacing = max(width * 0.07, 1.5)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(relativeHeights.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(foregroundStyle)
                        .frame(width: barWidth, height: height * relativeHeights[index])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct SpkLogoMark: View {
    var foregroundStyle: Color = .primary
    var badgeColor: Color? = nil

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let badgeSize = max(size * 0.24, 6)

            ZStack(alignment: .topTrailing) {
                SpkWaveGlyph(foregroundStyle: foregroundStyle)
                    .frame(width: size * 0.72, height: size * 0.72)
                    .frame(width: size, height: size)

                if let badgeColor {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: badgeSize, height: badgeSize)
                        .overlay {
                            Circle()
                                .strokeBorder(.background.opacity(0.35), lineWidth: max(size * 0.03, 1))
                        }
                        .offset(x: size * 0.04, y: -size * 0.04)
                }
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct SpkMenuBarIcon: View {
    let isRecording: Bool

    private static let templateImage = SpkAppIconImage.makeTemplate(size: 18)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: Self.templateImage)
                .renderingMode(.template)
                .interpolation(.high)
                .resizable()
                .frame(width: 18, height: 18)

            if let badgeColor {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle()
                            .strokeBorder(.background.opacity(0.35), lineWidth: 1)
                    }
                    .offset(x: 1, y: -1)
            }
        }
        .frame(width: 18, height: 18)
        .fixedSize()
        .accessibilityLabel("spk")
    }

    private var badgeColor: Color? {
        isRecording ? .red : nil
    }
}

enum SpkAppIconImage {
    static let assetForegroundColor = NSColor(
        srgbRed: 0.23,
        green: 0.24,
        blue: 0.19,
        alpha: 1.0
    )

    static let assetBackgroundColor = NSColor(
        srgbRed: 0.88,
        green: 0.80,
        blue: 0.69,
        alpha: 1.0
    )

    static func make(
        size: CGFloat = 128,
        foregroundColor: NSColor = assetForegroundColor,
        backgroundColor: NSColor? = assetBackgroundColor
    ) -> NSImage {
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(size: canvas.size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        if let backgroundColor {
            drawBackground(in: canvas, backgroundColor: backgroundColor)
        }
        drawWaveGlyph(in: canvas, foregroundColor: foregroundColor)
        image.isTemplate = false
        return image
    }

    static func makeTemplate(size: CGFloat = 18) -> NSImage {
        let image = make(size: size, foregroundColor: .white, backgroundColor: nil)
        image.isTemplate = true
        return image
    }

    private static func drawBackground(in canvas: NSRect, backgroundColor: NSColor) {
        let inset = min(canvas.width, canvas.height) * 0.08
        let backgroundRect = canvas.insetBy(dx: inset, dy: inset)
        let backgroundPath = NSBezierPath(ovalIn: backgroundRect)
        backgroundColor.setFill()
        backgroundPath.fill()
    }

    private static func drawWaveGlyph(in canvas: NSRect, foregroundColor: NSColor) {
        let glyphSide = min(canvas.width, canvas.height) * 0.72
        let glyphRect = NSRect(
            x: canvas.midX - glyphSide / 2,
            y: canvas.midY - glyphSide / 2,
            width: glyphSide,
            height: glyphSide
        )
        let barWidth = max(glyphRect.width * 0.12, 1.5)
        let spacing = max(glyphRect.width * 0.07, 1.0)
        let totalWidth = CGFloat(SpkLogoMetrics.relativeHeights.count) * barWidth +
            CGFloat(SpkLogoMetrics.relativeHeights.count - 1) * spacing
        let startX = glyphRect.midX - totalWidth / 2

        foregroundColor.setFill()

        for (index, relativeHeight) in SpkLogoMetrics.relativeHeights.enumerated() {
            let barHeight = glyphRect.height * relativeHeight
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = glyphRect.midY - barHeight / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let capsule = NSBezierPath(
                roundedRect: rect,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            )
            capsule.fill()
        }
    }
}
