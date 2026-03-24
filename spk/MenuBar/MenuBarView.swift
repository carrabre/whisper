import SwiftUI

struct MenuBarView: View {
    private enum Pane: String, CaseIterable {
        case dictation = "Dictation"
        case settings = "Settings"
    }

    @EnvironmentObject private var appState: WhisperAppState
    @EnvironmentObject private var audioSettings: AudioSettingsStore
    @State private var selectedPane: Pane = .dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            panePicker

            if selectedPane == .dictation {
                heroCard

                if !appState.lastTranscript.isEmpty {
                    transcriptCard
                }
            } else {
                settingsCard
            }

            utilityRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            appState.refreshPermissions()
            audioSettings.refreshInputDevices()
        }
        .onChange(of: selectedPane) { newValue in
            if newValue == .settings {
                audioSettings.refreshInputDevices()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(spacing: 12) {
                SpkLogoMark()
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("spk")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))

                    Text("Dictation into the focused app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(selectedPane == .settings ? "Settings" : appState.statusTitle)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusBadgeBackground)
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.12))
                }
        }
    }

    private var panePicker: some View {
        Picker("Section", selection: $selectedPane) {
            ForEach(Pane.allCases, id: \.self) { pane in
                Text(pane.rawValue)
                    .tag(pane)
            }
        }
        .pickerStyle(.segmented)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SpkLogoMark(badgeColor: statusIconBadgeColor)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.statusMessage)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(appState.modelMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Input Level")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(appState.isRecording ? "Live" : "Idle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            appState.isRecording
                                ? AnyShapeStyle(Color.red)
                                : AnyShapeStyle(.tertiary)
                        )
                }

                inputLevelMeter
            }

            Button {
                Task {
                    await appState.toggleRecordingFromButton()
                }
            } label: {
                HStack {
                    Image(systemName: recordButtonSymbolName)
                    Text(recordButtonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recordButtonTint)
            .disabled(!appState.canRecord)

            Text("Shortcut: press \(appState.hotkeyHint) to start recording, then press it again to transcribe into the focused app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var inputLevelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.08))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.green.opacity(0.95),
                                Color.yellow.opacity(0.95),
                                Color.orange.opacity(0.95)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * appState.liveInputLevel)
                    .opacity(appState.isRecording ? 1 : 0.35)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.08), value: appState.liveInputLevel)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))

            permissionRow(
                title: "Microphone",
                permission: appState.permissions.microphone
            ) {
                if appState.permissions.microphone.needsSystemSettings {
                    appState.openMicrophoneSettings()
                } else {
                    Task {
                        await appState.requestMicrophonePermission()
                    }
                }
            }

            permissionRow(
                title: "Accessibility",
                permission: appState.permissions.accessibility
            ) {
                appState.requestAccessibilityPermission()
            }

            if !appState.modelReady {
                Button(appState.isPreparingModel ? "Preparing whisper-medium..." : "Finish Model Setup") {
                    Task {
                        await appState.retryModelSetup()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isPreparingModel)
            }

            HStack {
                Spacer()

                Button("Refresh") {
                    appState.refreshPermissions()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.subheadline.weight(.semibold))

            Toggle("Automatically Copy To Clipboard", isOn: $audioSettings.automaticallyCopyTranscripts)
                .toggleStyle(.switch)

            Text("When enabled, every completed transcript is copied to the clipboard. When disabled, spk leaves the clipboard alone unless you use Copy manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Copy") {
                    appState.copyLastTranscript()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(appState.lastTranscript)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            permissionsSection

            Divider()

            transcriptSettingsSection

            Divider()

            Text("Recording Settings")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input Device")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Refresh") {
                        audioSettings.refreshInputDevices()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Picker("Microphone", selection: selectedInputDeviceSelection) {
                    Text("System Default (\(audioSettings.defaultInputDeviceName))")
                        .tag(AudioSettingsStore.systemDefaultSelectionID)

                    ForEach(audioSettings.availableInputDevices) { device in
                        Text(device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(
                    audioSettings.selectedInputDeviceID == nil
                        ? "Uses whichever microphone macOS is currently using by default."
                        : "spk switches to this microphone while recording, then restores the previous default when you stop."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input Sensitivity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(audioSettings.sensitivityDisplay)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $audioSettings.inputSensitivity,
                    in: AudioSettingsStore.sensitivityRange,
                    step: 0.1
                )

                HStack {
                    Text("Lower")
                    Spacer()
                    Text("Higher")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                Text("Higher sensitivity boosts quieter voices before transcription, but it also raises background noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Diagnostics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Copy Debug Log") {
                        appState.copyDebugLog()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Show Log File") {
                        appState.revealDebugLog()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text(appState.debugLogPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var utilityRow: some View {
        HStack(spacing: 10) {
            Button {
                appState.openModelFolder()
            } label: {
                Label("Model Files", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive) {
                appState.quit()
            } label: {
                Label("Quit spk", systemImage: "power")
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 4)
    }

    private var selectedInputDeviceSelection: Binding<String> {
        Binding(
            get: { audioSettings.selectedInputDeviceSelection },
            set: { audioSettings.updateSelectedInputDeviceSelection($0) }
        )
    }

    private var recordButtonTitle: String {
        if appState.isRecording {
            return "Stop Recording"
        }
        if appState.isTranscribing {
            return "Transcribing..."
        }
        if appState.isInserting {
            return "Finishing..."
        }
        return "Start Recording"
    }

    private var recordButtonSymbolName: String {
        if appState.isRecording {
            return "stop.fill"
        }
        if appState.isTranscribing {
            return "waveform.and.magnifyingglass"
        }
        if appState.isInserting {
            return "square.and.arrow.down.on.square"
        }
        return "mic.fill"
    }

    private var recordButtonTint: Color {
        if appState.isRecording {
            return .red
        }
        if appState.isTranscribing {
            return .orange
        }
        if appState.isInserting {
            return .blue
        }
        return .accentColor
    }

    private var statusIconBadgeColor: Color? {
        appState.isRecording ? .red : nil
    }

    private func permissionRow(title: String, permission: PermissionState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(permission.isGranted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.subheadline.weight(.medium))

            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(permission.explanation)

            Spacer()

            if permission.isGranted {
                Text(permission.description)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(permission.needsSystemSettings ? "Open Settings" : "Grant", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
    }

    private var statusBadgeBackground: some ShapeStyle {
        if appState.isRecording {
            return AnyShapeStyle(Color.red.opacity(0.16))
        }
        if appState.isTranscribing {
            return AnyShapeStyle(Color.orange.opacity(0.16))
        }
        if appState.isInserting {
            return AnyShapeStyle(Color.blue.opacity(0.16))
        }
        if !appState.permissions.microphone.isGranted || !appState.permissions.accessibility.isGranted {
            return AnyShapeStyle(Color.yellow.opacity(0.16))
        }
        return AnyShapeStyle(Color.green.opacity(0.16))
    }
}
