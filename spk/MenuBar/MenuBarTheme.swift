import SwiftUI

struct SpkPalette {
    let background: Color
    let logoBackdrop: Color
    let sectionTint: Color
    let surface: Color
    let surfaceStrong: Color
    let surfaceMuted: Color
    let border: Color
    let borderStrong: Color
    let text: Color
    let mutedText: Color
    let subtleText: Color
    let primaryFill: Color
    let primaryText: Color
    let secondaryFill: Color
    let secondaryText: Color
    let meterTrack: Color
    let meterOutline: Color
    let shadow: Color
}

enum SpkTheme {
    enum Space {
        static let xxSmall: CGFloat = 6
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 24
        static let section: CGFloat = 28
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 22
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let eyebrow = Font.system(size: 12, weight: .medium)
        static let detail = Font.system(size: 13, weight: .regular)
        static let detailStrong = Font.system(size: 13, weight: .medium)
        static let body = Font.system(size: 15, weight: .regular)
        static let bodyStrong = Font.system(size: 15, weight: .medium)
        static let title = Font.system(size: 24, weight: .regular)
        static let sectionTitle = Font.system(size: 20, weight: .regular)
        static let brand = Font.system(size: 22, weight: .medium)
        static let button = Font.system(size: 14, weight: .regular)
        static let buttonStrong = Font.system(size: 14, weight: .medium)
    }

    static func palette(for colorScheme: ColorScheme) -> SpkPalette {
        if colorScheme == .dark {
            return SpkPalette(
                background: .spk(29, 29, 24),
                logoBackdrop: .spk(118, 95, 68),
                sectionTint: .spk(36, 35, 30),
                surface: .spk(44, 43, 37),
                surfaceStrong: .spk(51, 49, 42),
                surfaceMuted: .spk(34, 33, 28),
                border: .spk(247, 247, 244, opacity: 0.10),
                borderStrong: .spk(247, 247, 244, opacity: 0.16),
                text: .spk(240, 238, 232),
                mutedText: .spk(240, 238, 232, opacity: 0.74),
                subtleText: .spk(240, 238, 232, opacity: 0.50),
                primaryFill: .spk(240, 238, 232),
                primaryText: .spk(32, 31, 26),
                secondaryFill: .spk(51, 49, 42),
                secondaryText: .spk(240, 238, 232),
                meterTrack: .spk(247, 247, 244, opacity: 0.08),
                meterOutline: .spk(247, 247, 244, opacity: 0.10),
                shadow: .black.opacity(0.28)
            )
        }

        return SpkPalette(
            background: .spk(247, 247, 244),
            logoBackdrop: .spk(224, 205, 176),
            sectionTint: .spk(239, 236, 228),
            surface: .spk(242, 241, 236),
            surfaceStrong: .spk(236, 232, 223),
            surfaceMuted: .spk(250, 249, 245),
            border: .spk(38, 37, 30, opacity: 0.12),
            borderStrong: .spk(38, 37, 30, opacity: 0.18),
            text: .spk(38, 37, 30),
            mutedText: .spk(38, 37, 30, opacity: 0.72),
            subtleText: .spk(38, 37, 30, opacity: 0.46),
            primaryFill: .spk(38, 37, 30),
            primaryText: .spk(247, 247, 244),
            secondaryFill: .spk(250, 249, 245),
            secondaryText: .spk(38, 37, 30),
            meterTrack: .spk(38, 37, 30, opacity: 0.08),
            meterOutline: .spk(38, 37, 30, opacity: 0.10),
            shadow: .black.opacity(0.05)
        )
    }
}

enum SpkPillButtonVariant {
    case primary
    case secondary
    case plain
    case destructive
}

struct SpkPillButtonStyle: ButtonStyle {
    let palette: SpkPalette
    let variant: SpkPillButtonVariant
    var emphasized = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(emphasized ? SpkTheme.Typography.buttonStrong : SpkTheme.Typography.button)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, variant == .plain ? 0 : 12)
            .padding(.vertical, variant == .plain ? 0 : 8)
            .background {
                if variant != .plain {
                    Capsule(style: .continuous)
                        .fill(backgroundColor)
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(borderColor, lineWidth: 1)
                        }
                }
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return palette.primaryText
        case .secondary:
            return palette.secondaryText
        case .plain:
            return palette.text
        case .destructive:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary:
            return palette.primaryFill
        case .secondary:
            return palette.secondaryFill
        case .plain:
            return .clear
        case .destructive:
            return .red.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            return palette.primaryFill
        case .secondary:
            return palette.border
        case .plain:
            return .clear
        case .destructive:
            return .red.opacity(0.22)
        }
    }
}

struct SpkSurfaceModifier: ViewModifier {
    let palette: SpkPalette
    let fill: Color
    let radius: CGFloat
    let padding: CGFloat
    var shadow = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    }
                    .shadow(
                        color: shadow ? palette.shadow : .clear,
                        radius: shadow ? 18 : 0,
                        x: 0,
                        y: shadow ? 10 : 0
                    )
            }
    }
}

extension View {
    func spkSurface(
        palette: SpkPalette,
        fill: Color? = nil,
        radius: CGFloat = SpkTheme.Radius.medium,
        padding: CGFloat = SpkTheme.Space.medium,
        shadow: Bool = false
    ) -> some View {
        modifier(
            SpkSurfaceModifier(
                palette: palette,
                fill: fill ?? palette.surface,
                radius: radius,
                padding: padding,
                shadow: shadow
            )
        )
    }
}

struct SpkDivider: View {
    let palette: SpkPalette

    var body: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

private extension Color {
    static func spk(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
    }
}
