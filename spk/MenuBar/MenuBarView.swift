import SwiftUI

struct MenuBarView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case dictation = "Dictation"
        case settings = "Settings"

        var id: Self { self }
    }

    @EnvironmentObject private var appState: WhisperAppState
    @EnvironmentObject private var audioSettings: AudioSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedPane: Pane = .dictation

    private var palette: SpkPalette {
        SpkTheme.palette(for: colorScheme)
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(
                alignment: .leading,
                spacing: selectedPane == .settings ? SpkTheme.Space.small : SpkTheme.Space.medium
            ) {
                header
                panePicker

                if selectedPane == .dictation {
                    dictationContent
                } else {
                    settingsPane
                }

                utilityRow
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .onAppear {
            appState.refreshPermissions()
            audioSettings.refreshInputDevices()
        }
        .onChange(of: selectedPane) { _, newValue in
            if newValue == .settings {
                audioSettings.refreshInputDevices()
            }
        }
        .onChange(of: audioSettings.transcriptionBackendSelection) { _, _ in
            Task {
                await appState.invalidatePreparedBackendConfiguration()
                await appState.retryModelSetup()
            }
        }
        .onChange(of: audioSettings.voxtralRealtimeModelFolderPath) { _, _ in
            guard audioSettings.transcriptionBackendSelection == .voxtralRealtime else { return }
            Task {
                await appState.invalidatePreparedBackendConfiguration()
                await appState.retryModelSetup()
            }
        }
    }

    private var settingsPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            settingsContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 624)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SpkTheme.Space.small) {
            HStack(spacing: SpkTheme.Space.small) {
                ZStack {
                    Circle()
                        .fill(palette.logoBackdrop)
                        .overlay {
                            Circle()
                                .stroke(palette.border, lineWidth: 1)
                        }

                    SpkLogoMark(
                        foregroundStyle: palette.text,
                        badgeColor: statusIconBadgeColor
                    )
                    .frame(width: 22, height: 22)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("spk")
                        .font(SpkTheme.Typography.brand)
                        .foregroundStyle(palette.text)

                    Text("Local dictation into the focused app.")
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: SpkTheme.Space.small)

            HStack(spacing: 6) {
                if selectedPane != .settings && appState.showsStartupSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.text)
                }

                Text(selectedPane == .settings ? "Settings" : appState.statusTitle)
                    .font(SpkTheme.Typography.detailStrong)
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(statusBadgeBackground)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    }
            }
        }
    }

    private var panePicker: some View {
        HStack(spacing: 6) {
            ForEach(Pane.allCases) { pane in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selectedPane = pane
                    }
                } label: {
                    Text(pane.rawValue)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    SpkPillButtonStyle(
                        palette: palette,
                        variant: selectedPane == pane ? .primary : .secondary,
                        emphasized: selectedPane == pane
                    )
                )
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(palette.sectionTint)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                }
        }
    }

    private var dictationContent: some View {
        VStack(alignment: .leading, spacing: SpkTheme.Space.small) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.statusTitle)
                        .font(SpkTheme.Typography.sectionTitle)
                        .foregroundStyle(palette.text)

                    Text(appState.statusMessage)
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(3)
                }

                if appState.shouldShowStartupReadinessProgress {
                    StartupReadinessCard(
                        palette: palette,
                        title: appState.startupProgressTitle,
                        summary: appState.startupProgressSummary,
                        progress: appState.startupProgressFraction,
                        isLoading: appState.showsStartupSpinner,
                        hasIssue: appState.startupNeedsAttention,
                        checklistItems: appState.startupChecklistItems
                    )
                }

                if appState.shouldShowStreamingPreviewCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Voice input")
                            .font(SpkTheme.Typography.eyebrow)
                            .foregroundStyle(palette.mutedText)

                        Text(appState.streamingPreviewDisplayText)
                            .font(SpkTheme.Typography.body)
                            .foregroundStyle(palette.text)
                            .lineLimit(4)
                            .truncationMode(.tail)

                        inputLevelMeter
                            .frame(height: 8)
                    }
                    .spkSurface(
                        palette: palette,
                        fill: palette.surface,
                        radius: SpkTheme.Radius.medium,
                        padding: 14
                    )
                }

                Button {
                    Task {
                        await appState.toggleRecordingFromButton()
                    }
                } label: {
                    HStack(spacing: SpkTheme.Space.xSmall) {
                        if appState.showsStartupSpinner && !appState.isRecording && !appState.isTranscribing && !appState.isInserting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(actionPalette.primaryText)
                        } else if appState.startupNeedsAttention && !appState.isRecording && !appState.isTranscribing && !appState.isInserting {
                            Image(systemName: "exclamationmark.triangle.fill")
                        } else {
                            Image(systemName: recordButtonSymbolName)
                        }
                        Text(recordButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    SpkPillButtonStyle(
                        palette: actionPalette,
                        variant: .primary,
                        emphasized: true
                    )
                )
                .disabled(!appState.canRecord)
            }
            .spkSurface(
                palette: palette,
                fill: palette.surfaceStrong,
                radius: SpkTheme.Radius.large,
                padding: 16,
                shadow: true
            )

            if !appState.lastTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Last transcript")
                            .font(SpkTheme.Typography.eyebrow)
                            .foregroundStyle(palette.mutedText)

                        Spacer()

                        Button("Copy") {
                            appState.copyLastTranscript()
                        }
                        .buttonStyle(
                            SpkPillButtonStyle(
                                palette: palette,
                                variant: .secondary,
                                emphasized: true
                            )
                        )
                    }

                    Text(appState.lastTranscript)
                        .font(SpkTheme.Typography.body)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
                .spkSurface(
                    palette: palette,
                    fill: palette.surface,
                    radius: SpkTheme.Radius.medium,
                    padding: 14
                )
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: SpkTheme.Space.small) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(SpkTheme.Typography.sectionTitle)
                            .foregroundStyle(palette.text)

                        Text(settingsSummary)
                            .font(SpkTheme.Typography.detail)
                            .foregroundStyle(palette.mutedText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: SpkTheme.Space.small)

                    Button("Refresh") {
                        appState.refreshPermissions()
                        audioSettings.refreshInputDevices()
                    }
                    .buttonStyle(
                        SpkPillButtonStyle(
                            palette: palette,
                            variant: .plain,
                            emphasized: true
                        )
                    )
                }

                PermissionRow(
                    palette: palette,
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

                PermissionRow(
                    palette: palette,
                    title: "Accessibility",
                    permission: appState.permissions.accessibility
                ) {
                    appState.requestAccessibilityPermission()
                }

                SigningStatusRow(
                    palette: palette,
                    status: appState.codeSigningStatus
                )

                if shouldShowModelSetupCard {
                    HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Model setup")
                                .font(SpkTheme.Typography.bodyStrong)
                                .foregroundStyle(palette.text)

                            Text(modelSetupSummary)
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: SpkTheme.Space.small)

                        Button(modelSetupActionTitle) {
                            Task {
                                await appState.retryModelSetup()
                            }
                        }
                        .buttonStyle(
                            SpkPillButtonStyle(
                                palette: palette,
                                variant: .secondary,
                                emphasized: true
                            )
                        )
                        .disabled(appState.isPreparingModel)
                    }
                    .spkSurface(
                        palette: palette,
                        fill: palette.surfaceMuted,
                        radius: 12,
                        padding: 12
                    )
                }

                SpkDivider(palette: palette)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcription backend")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Spacer()
                    }

                    Picker("Transcription backend", selection: $audioSettings.transcriptionBackendSelection) {
                        ForEach(TranscriptionBackendSelection.allCases) { backend in
                            Text(backend.displayName)
                                .tag(backend)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Text("\(audioSettings.transcriptionDisplayName) (\(audioSettings.transcriptionModelName))")
                        .font(SpkTheme.Typography.body)
                        .foregroundStyle(palette.text)

                    Text("Supported languages: \(audioSettings.transcriptionModelSupportedLanguages)")
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(audioSettings.transcriptionBackendSelection == .voxtralRealtime ? 4 : 1)

                    Text(appState.transcriptionModeDescription)
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(2)
                }

                SpkDivider(palette: palette)

                if audioSettings.transcriptionBackendSelection == .whisper {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Live preview (experimental)")
                                    .font(SpkTheme.Typography.bodyStrong)
                                    .foregroundStyle(palette.text)

                                Text(audioSettings.experimentalStreamingSummary)
                                    .font(SpkTheme.Typography.detail)
                                    .foregroundStyle(palette.mutedText)
                                    .lineLimit(2)

                                Text("Supported languages: \(audioSettings.experimentalStreamingSupportedLanguages)")
                                    .font(SpkTheme.Typography.detail)
                                    .foregroundStyle(palette.mutedText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: SpkTheme.Space.small)

                            Toggle("", isOn: $audioSettings.experimentalStreamingPreviewEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(palette.primaryFill)
                        }

                        if let selectedFolder = audioSettings.experimentalStreamingSelectedFolderDisplay {
                            Text(selectedFolder)
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        if audioSettings.experimentalStreamingPreviewEnabled {
                            HStack(spacing: SpkTheme.Space.small) {
                                Button(
                                    audioSettings.experimentalStreamingModelFolderPath == nil
                                        ? "Choose Folder"
                                        : "Change Folder"
                                ) {
                                    appState.chooseStreamingPreviewModelFolder()
                                }
                                .buttonStyle(
                                    SpkPillButtonStyle(
                                        palette: palette,
                                        variant: .secondary,
                                        emphasized: true
                                    )
                                )

                                if audioSettings.experimentalStreamingModelFolderPath != nil {
                                    Button("Clear") {
                                        appState.clearStreamingPreviewModelFolder()
                                    }
                                    .buttonStyle(
                                        SpkPillButtonStyle(
                                            palette: palette,
                                            variant: .plain,
                                            emphasized: true
                                        )
                                    )
                                }
                            }

                            Text("During recording, spk can show partial WhisperKit text in the Dictation pane. The final inserted transcript still uses Whisper.")
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(2)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Voxtral model (fastest local realtime)")
                                .font(SpkTheme.Typography.bodyStrong)
                                .foregroundStyle(palette.text)

                            Text(audioSettings.voxtralRealtimeSummary)
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(3)

                            Text("Supported languages: \(audioSettings.voxtralRealtimeSupportedLanguages)")
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(4)
                        }

                        if let selectedFolder = audioSettings.voxtralRealtimeSelectedFolderDisplay {
                            Text(selectedFolder)
                                .font(SpkTheme.Typography.detail)
                                .foregroundStyle(palette.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: SpkTheme.Space.small) {
                            Button(
                                audioSettings.voxtralRealtimeModelFolderPath == nil
                                    ? "Choose Folder"
                                    : "Change Folder"
                            ) {
                                appState.chooseVoxtralRealtimeModelFolder()
                            }
                            .buttonStyle(
                                SpkPillButtonStyle(
                                    palette: palette,
                                    variant: .secondary,
                                    emphasized: true
                                )
                            )

                            if audioSettings.voxtralRealtimeModelFolderPath != nil {
                                Button("Clear") {
                                    appState.clearVoxtralRealtimeModelFolder()
                                }
                                .buttonStyle(
                                    SpkPillButtonStyle(
                                        palette: palette,
                                        variant: .plain,
                                        emphasized: true
                                    )
                                )
                            }
                        }
                    }
                }

                SpkDivider(palette: palette)

                HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatically copy transcripts")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Text(audioSettings.automaticallyCopyTranscripts ? "Each finished transcript is copied automatically after it is ready." : "Leave the clipboard untouched until you press Copy.")
                            .font(SpkTheme.Typography.detail)
                            .foregroundStyle(palette.mutedText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: SpkTheme.Space.small)

                    Toggle("", isOn: $audioSettings.automaticallyCopyTranscripts)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(palette.primaryFill)
                }

                SpkDivider(palette: palette)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: SpkTheme.Space.small) {
                        Text("Input device")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Spacer()

                        Button("Refresh") {
                            audioSettings.refreshInputDevices()
                        }
                        .buttonStyle(
                            SpkPillButtonStyle(
                                palette: palette,
                                variant: .secondary
                            )
                        )
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
                            ? "Uses the current macOS default microphone."
                            : "spk switches to this microphone only while recording."
                    )
                    .font(SpkTheme.Typography.detail)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Input sensitivity")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Spacer()

                        Text(audioSettings.sensitivityDisplay)
                            .font(SpkTheme.Typography.detailStrong)
                            .foregroundStyle(palette.mutedText)
                    }

                    Slider(
                        value: $audioSettings.inputSensitivity,
                        in: AudioSettingsStore.sensitivityRange,
                        step: 0.1
                    )
                    .tint(palette.primaryFill)

                    Text("Higher values lift quieter speech, but also more background noise.")
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(2)
                }

                SpkDivider(palette: palette)

                HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allow paste fallback")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Text(audioSettings.allowPasteFallback ? "If typing recovery still fails, spk will paste into the frozen non-secure target and restore your clipboard when possible." : "Turn this off only if you do not want clipboard-based recovery when direct insertion and typing fail.")
                            .font(SpkTheme.Typography.detail)
                            .foregroundStyle(palette.mutedText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: SpkTheme.Space.small)

                    Toggle("", isOn: $audioSettings.allowPasteFallback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(palette.primaryFill)
                }

                SpkDivider(palette: palette)

                HStack(alignment: .top, spacing: SpkTheme.Space.small) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Collect diagnostics")
                            .font(SpkTheme.Typography.bodyStrong)
                            .foregroundStyle(palette.text)

                        Text(audioSettings.diagnosticsEnabled ? "Keep a redacted in-memory diagnostics buffer available for manual copy or export." : "Stop collecting diagnostics entirely and clear the current in-memory buffer.")
                            .font(SpkTheme.Typography.detail)
                            .foregroundStyle(palette.mutedText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: SpkTheme.Space.small)

                    Toggle("", isOn: $audioSettings.diagnosticsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(palette.primaryFill)
                }

                SpkDivider(palette: palette)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: SpkTheme.Space.small) {
                        Button("Copy Diagnostics") {
                            appState.copyDebugLog()
                        }
                        .buttonStyle(
                            SpkPillButtonStyle(
                                palette: palette,
                                variant: .secondary
                            )
                        )
                        .disabled(!audioSettings.diagnosticsEnabled)

                        Button("Export Diagnostics") {
                            appState.exportDebugLog()
                        }
                        .buttonStyle(
                            SpkPillButtonStyle(
                                palette: palette,
                                variant: .secondary
                            )
                        )
                        .disabled(!audioSettings.diagnosticsEnabled)
                    }

                    Text(appState.debugLogPath)
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.subtleText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .controlSize(.small)
            .spkSurface(
                palette: palette,
                fill: palette.surface,
                radius: SpkTheme.Radius.medium,
                padding: 12
            )
        }
    }

    private var utilityRow: some View {
        HStack(spacing: SpkTheme.Space.small) {
            Button {
                appState.openModelFolder()
            } label: {
                Label("Model Files", systemImage: "folder")
            }
            .buttonStyle(
                SpkPillButtonStyle(
                    palette: palette,
                    variant: .secondary,
                    emphasized: true
                )
            )

            Spacer(minLength: SpkTheme.Space.small)

            Button(role: .destructive) {
                appState.quit()
            } label: {
                Label("Quit spk", systemImage: "power")
            }
            .keyboardShortcut("q")
            .buttonStyle(
                SpkPillButtonStyle(
                    palette: palette,
                    variant: .destructive,
                    emphasized: true
                )
            )
        }
        .padding(.top, 2)
    }

    private var inputLevelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.meterTrack)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.green.opacity(0.90),
                                Color.yellow.opacity(0.90),
                                Color.orange.opacity(0.90)
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
                    .strokeBorder(palette.meterOutline, lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.08), value: appState.liveInputLevel)
    }

    private var selectedInputDeviceSelection: Binding<String> {
        Binding(
            get: { audioSettings.selectedInputDeviceSelection },
            set: { audioSettings.updateSelectedInputDeviceSelection($0) }
        )
    }

    private var actionPalette: SpkPalette {
        if appState.showsVisibleRecordingStartState {
            return palette.withPrimaryFill(.orange, text: .white)
        }
        if appState.isRecording {
            return palette.withPrimaryFill(.red, text: .white)
        }
        if appState.isTranscribing {
            return palette.withPrimaryFill(.orange, text: .white)
        }
        if appState.isInserting {
            return palette.withPrimaryFill(.blue, text: .white)
        }
        return palette
    }

    private var settingsSummary: String {
        appState.setupSummary
    }

    private var recordButtonTitle: String {
        if appState.shouldShowStartupReadinessProgress {
            return appState.startupNeedsAttention
                ? "Finish \(audioSettings.transcriptionDisplayName) Setup"
                : "Preparing \(audioSettings.transcriptionDisplayName)..."
        }
        if appState.showsVisibleRecordingStartState {
            return "Cancel Start"
        }
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
        if appState.showsVisibleRecordingStartState {
            return "xmark"
        }
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

    private var statusIconBadgeColor: Color? {
        if appState.isRecording {
            return .red
        }
        if appState.showsStartupSpinner {
            return .orange
        }
        if appState.startupNeedsAttention {
            return .yellow
        }
        return nil
    }

    private var statusBadgeBackground: Color {
        if appState.isRecording {
            return .red.opacity(0.16)
        }
        if appState.isTranscribing {
            return .orange.opacity(0.18)
        }
        if appState.isInserting {
            return .blue.opacity(0.16)
        }
        switch appState.startupSetupPhase {
        case .requestingMicrophone, .requestingAccessibility,
             .failed(.microphonePermission), .failed(.accessibilityPermission):
            return .yellow.opacity(0.18)
        case .checkingSigning, .preparingBackend,
             .failed(.unstableSigning), .failed(.backend):
            return .orange.opacity(0.18)
        case .ready:
            return .green.opacity(0.16)
        }
    }

    private var shouldShowModelSetupCard: Bool {
        switch appState.startupSetupPhase {
        case .preparingBackend, .failed(.backend):
            return true
        case .checkingSigning:
            return !appState.modelReady && appState.hasStableSigningIdentity
        case .requestingMicrophone, .requestingAccessibility, .failed, .ready:
            return false
        }
    }

    private var modelSetupSummary: String {
        switch appState.startupSetupPhase {
        case .preparingBackend:
            return appState.statusMessage
        case .failed(let failure):
            switch failure {
            case .backend(let message):
                return message
            case .unstableSigning, .microphonePermission, .accessibilityPermission:
                return "Finish \(audioSettings.transcriptionDisplayName) setup."
            }
        case .checkingSigning, .requestingMicrophone, .requestingAccessibility, .ready:
            return appState.modelReady
                ? "Ready locally: \(audioSettings.transcriptionModelName)."
                : "Finish \(audioSettings.transcriptionDisplayName) setup."
        }
    }

    private var modelSetupActionTitle: String {
        appState.isPreparingModel ? "Preparing..." : "Finish Setup"
    }

}

private struct StartupReadinessCard: View {
    let palette: SpkPalette
    let title: String
    let summary: String
    let progress: Double
    let isLoading: Bool
    let hasIssue: Bool
    let checklistItems: [StartupChecklistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: SpkTheme.Space.small) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.text)
                } else if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SpkTheme.Typography.bodyStrong)
                        .foregroundStyle(palette.text)

                    Text(summary)
                        .font(SpkTheme.Typography.detail)
                        .foregroundStyle(palette.mutedText)
                }
            }

            ProgressView(value: progress, total: 1)
                .tint(palette.primaryFill)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(checklistItems) { item in
                    StartupChecklistRow(palette: palette, item: item)
                }
            }
        }
        .spkSurface(
            palette: palette,
            fill: palette.surfaceMuted,
            radius: 12,
            padding: 10
        )
    }
}

private struct StartupChecklistRow: View {
    let palette: SpkPalette
    let item: StartupChecklistItem

    var body: some View {
        HStack(alignment: .top, spacing: SpkTheme.Space.small) {
            icon
                .frame(width: 14, height: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SpkTheme.Typography.detailStrong)
                    .foregroundStyle(palette.text)

                Text(item.detail)
                    .font(SpkTheme.Typography.detail)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(palette.text)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(palette.subtleText)
        case .blocked:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct PermissionRow: View {
    let palette: SpkPalette
    let title: String
    let permission: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(spacing: SpkTheme.Space.small) {
            Circle()
                .fill(permission.isGranted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(SpkTheme.Typography.bodyStrong)
                        .foregroundStyle(palette.text)

                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.subtleText)
                        .help(permission.explanation)
                }

                Text(permission.description)
                    .font(SpkTheme.Typography.detail)
                    .foregroundStyle(permission.isGranted ? .green : palette.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: SpkTheme.Space.small)

            if permission.isGranted {
                Text("Granted")
                    .font(SpkTheme.Typography.detailStrong)
                    .foregroundStyle(.green)
            } else {
                Button(permission.needsSystemSettings ? "Open" : "Grant", action: action)
                    .buttonStyle(
                        SpkPillButtonStyle(
                            palette: palette,
                            variant: .secondary,
                            emphasized: true
                        )
                    )
            }
        }
        .spkSurface(
            palette: palette,
            fill: palette.surfaceMuted,
            radius: 12,
            padding: 10
        )
    }
}

private struct SigningStatusRow: View {
    let palette: SpkPalette
    let status: CodeSigningStatus

    var body: some View {
        HStack(alignment: .top, spacing: SpkTheme.Space.small) {
            Circle()
                .fill(status.hasStableIdentity ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("App identity")
                    .font(SpkTheme.Typography.bodyStrong)
                    .foregroundStyle(palette.text)

                Text(status.statusLabel)
                    .font(SpkTheme.Typography.detailStrong)
                    .foregroundStyle(status.hasStableIdentity ? .green : palette.text)

                Text(status.explanation)
                    .font(SpkTheme.Typography.detail)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: SpkTheme.Space.small)
        }
        .spkSurface(
            palette: palette,
            fill: palette.surfaceMuted,
            radius: 12,
            padding: 10
        )
    }
}

private extension SpkPalette {
    func withPrimaryFill(_ fill: Color, text: Color) -> SpkPalette {
        SpkPalette(
            background: background,
            logoBackdrop: logoBackdrop,
            sectionTint: sectionTint,
            surface: surface,
            surfaceStrong: surfaceStrong,
            surfaceMuted: surfaceMuted,
            border: border,
            borderStrong: borderStrong,
            text: self.text,
            mutedText: mutedText,
            subtleText: subtleText,
            primaryFill: fill,
            primaryText: text,
            secondaryFill: secondaryFill,
            secondaryText: secondaryText,
            meterTrack: meterTrack,
            meterOutline: meterOutline,
            shadow: shadow
        )
    }
}
