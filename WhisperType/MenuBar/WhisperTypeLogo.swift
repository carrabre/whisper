import SwiftUI

struct WhisperTypeLogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.92), Color.blue.opacity(0.76)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 3) {
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(width: 7, height: 15)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white.opacity(0.74))
                    .frame(width: 16, height: 2)
            }

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

struct WhisperTypeMenuBarIcon: View {
    let isRecording: Bool
    let isBlinkVisible: Bool
    let isTranscribing: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: menuBarSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .accessibilityLabel("spk")

            if isRecording {
                Circle()
                    .fill(isBlinkVisible ? Color.red : Color.clear)
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: -1)
            } else if isTranscribing {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: -1)
            }
        }
    }

    private var menuBarSymbolName: String {
        if isRecording {
            return "mic.fill"
        }
        if isTranscribing {
            return "waveform.and.magnifyingglass"
        }
        return "waveform"
    }
}
