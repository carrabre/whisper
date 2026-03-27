import AppKit
import Foundation
import SwiftUI

struct WhisperAppDependencies {
    let installDefaultHotkey: (@escaping () -> Void) -> HotkeyManager.ListenerStatus
    let resetDefaultHotkey: () -> HotkeyManager.ListenerStatus
    let permissionSnapshot: () -> PermissionSnapshot
    let codeSigningStatus: () -> CodeSigningStatus
    let requestMicrophonePermission: () async -> Bool
    let promptForAccessibilityPermission: () -> Void
    let openMicrophoneSettings: () -> Void
    let openAccessibilitySettings: () -> Void
    let bundleVersionIdentifier: () -> String
    let lastAccessibilityStartupPromptVersion: () -> String?
    let setLastAccessibilityStartupPromptVersion: (String?) -> Void
    let audioStart: (String?) async throws -> Bool
    let audioStop: () async -> RecordingStopResult
    let normalizedInputLevel: () async -> Float
    let isExperimentalStreamingPreviewEnabled: () -> Bool
    let streamingPreviewSnapshot: () async -> StreamingPreviewSnapshot?
    let streamingPreviewUnavailableReason: () async -> String?
    let prepareTranscription: () async throws -> TranscriptionPreparation
    let modelDirectoryURL: () async throws -> URL
    let transcribePreparedRecording: ([Float]) async throws -> String
    let prepareRecordingForTranscription: (URL, Double) async throws -> PreparedRecording
    let prepareSamplesForTranscription: ([Float], Double) async throws -> PreparedRecording
    let captureInsertionTarget: () -> TextInsertionService.Target?
    let hasVisibleSpkWindows: () -> Bool
    let beginStreamingInsertionSession: (TextInsertionService.Target?) -> TextInsertionService.StreamingSession?
    let updateStreamingInsertionSession: (TextInsertionService.StreamingSession, String) -> Bool
    let commitStreamingInsertionSession: (TextInsertionService.StreamingSession, String, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome
    let cancelStreamingInsertionSession: (TextInsertionService.StreamingSession) -> Void
    let insertText: (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome
    let copyTextToClipboard: (String) -> Void
    let playAudioCue: (AudioCue) -> Void

    static func live(
        audioSettings: AudioSettingsStore,
        permissionsManager: PermissionsManager = PermissionsManager(),
        streamingCoordinator: WhisperKitStreamingCoordinator? = nil,
        audioRecorder: AudioRecorder? = nil,
        whisperBridge: WhisperBridge = WhisperBridge(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        hotkeyManager: HotkeyManager = HotkeyManager(),
        audioCuePlayer: AudioCuePlayer = AudioCuePlayer()
    ) -> Self {
        let userDefaults = UserDefaults.standard
        let accessibilityPromptDefaultsKey = "startup.accessibilityPromptVersion"
        let streamingSettingsProvider: @Sendable () async -> WhisperKitStreamingSettingsSnapshot = {
            await MainActor.run {
                audioSettings.experimentalStreamingSettingsSnapshot
            }
        }
        let resolvedStreamingCoordinator = streamingCoordinator ?? WhisperKitStreamingCoordinator(
            settingsSnapshotProvider: streamingSettingsProvider
        )
        let resolvedAudioRecorder = audioRecorder ?? AudioRecorder(streamingCoordinator: resolvedStreamingCoordinator)
        let transcriptionCoordinator = TranscriptionCoordinator(
            whisperBridge: whisperBridge,
            streamingCoordinator: resolvedStreamingCoordinator
        )

        return WhisperAppDependencies(
            installDefaultHotkey: { onTrigger in
                hotkeyManager.installDefault(onTrigger: onTrigger)
            },
            resetDefaultHotkey: {
                hotkeyManager.resetDefault()
            },
            permissionSnapshot: {
                permissionsManager.snapshot()
            },
            codeSigningStatus: {
                CodeSigningStatus.current()
            },
            requestMicrophonePermission: {
                await permissionsManager.requestMicrophonePermission()
            },
            promptForAccessibilityPermission: {
                permissionsManager.promptForAccessibilityPermission()
            },
            openMicrophoneSettings: {
                permissionsManager.openMicrophoneSettings()
            },
            openAccessibilitySettings: {
                permissionsManager.openAccessibilitySettings()
            },
            bundleVersionIdentifier: {
                let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                return "\(shortVersion)-\(buildNumber)"
            },
            lastAccessibilityStartupPromptVersion: {
                userDefaults.string(forKey: accessibilityPromptDefaultsKey)
            },
            setLastAccessibilityStartupPromptVersion: { versionIdentifier in
                if let versionIdentifier {
                    userDefaults.set(versionIdentifier, forKey: accessibilityPromptDefaultsKey)
                } else {
                    userDefaults.removeObject(forKey: accessibilityPromptDefaultsKey)
                }
            },
            audioStart: { preferredInputDeviceID in
                try await resolvedAudioRecorder.start(preferredInputDeviceID: preferredInputDeviceID)
            },
            audioStop: {
                await resolvedAudioRecorder.stop()
            },
            normalizedInputLevel: {
                await resolvedAudioRecorder.normalizedInputLevel()
            },
            isExperimentalStreamingPreviewEnabled: {
                MainActor.assumeIsolated {
                    WhisperKitStreamingModelLocator.isFeatureRequested(
                        environment: ProcessInfo.processInfo.environment,
                        settings: audioSettings.experimentalStreamingSettingsSnapshot
                    )
                }
            },
            streamingPreviewSnapshot: {
                await resolvedStreamingCoordinator.previewSnapshot()
            },
            streamingPreviewUnavailableReason: {
                await resolvedStreamingCoordinator.unavailablePreviewReason()
            },
            prepareTranscription: {
                try await transcriptionCoordinator.prepare()
            },
            modelDirectoryURL: {
                try await transcriptionCoordinator.modelDirectoryURL()
            },
            transcribePreparedRecording: { samples in
                try await transcriptionCoordinator.transcribePreparedRecording(samples: samples)
            },
            prepareRecordingForTranscription: { url, inputSensitivity in
                try await Task.detached(priority: .userInitiated) {
                    try AudioRecorder.prepareForTranscription(from: url, inputSensitivity: inputSensitivity)
                }.value
            },
            prepareSamplesForTranscription: { samples, inputSensitivity in
                await Task.detached(priority: .userInitiated) {
                    AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: inputSensitivity)
                }.value
            },
            captureInsertionTarget: {
                textInsertionService.captureInsertionTarget()
            },
            hasVisibleSpkWindows: {
                NSApplication.shared.windows.contains(where: \.isVisible)
            },
            beginStreamingInsertionSession: { target in
                textInsertionService.beginStreamingSession(target: target)
            },
            updateStreamingInsertionSession: { session, text in
                textInsertionService.updateStreamingSession(session, text: text)
            },
            commitStreamingInsertionSession: { session, text, options in
                textInsertionService.commitStreamingSession(session, finalText: text, options: options)
            },
            cancelStreamingInsertionSession: { session in
                textInsertionService.cancelStreamingSession(session)
            },
            insertText: { text, target, options in
                textInsertionService.insert(text, target: target, options: options)
            },
            copyTextToClipboard: { text in
                textInsertionService.copyToClipboard(text)
            },
            playAudioCue: { cue in
                audioCuePlayer.play(cue)
            }
        )
    }
}

@MainActor
final class WhisperAppState: ObservableObject {
    private static let insertionWatchdogDelay: TimeInterval = 3

    private enum RecordingTrigger {
        case button
        case hotkey

        var logDescription: String {
            switch self {
            case .button:
                return "button"
            case .hotkey:
                return "hotkey"
            }
        }
    }

    private enum RecordingDeliveryMode {
        case uiPreviewThenFinalInsert
        case liveExternalInsert

        var logDescription: String {
            switch self {
            case .uiPreviewThenFinalInsert:
                return "ui-preview-then-final-insert"
            case .liveExternalInsert:
                return "live-external-insert"
            }
        }
    }

    private struct RecordingDeliveryDecision {
        let mode: RecordingDeliveryMode
        let reason: String
        let hasVisibleSpkWindows: Bool
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isInserting = false
    @Published private(set) var modelReady = false
    @Published private(set) var statusMessage = "Starting up..."
    @Published private(set) var modelMessage = "Checking transcription backend..."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var permissions = PermissionSnapshot.current()
    @Published private(set) var codeSigningStatus = CodeSigningStatus.current()
    @Published private(set) var liveInputLevel: Double = 0
    @Published private(set) var streamingPreviewText = ""
    @Published private(set) var isStreamingPreviewActive = false
    @Published private(set) var hotkeyListenerStatus: HotkeyManager.ListenerStatus = .inactive
    @Published private(set) var startupSetupPhase: StartupSetupPhase = .checkingSigning

    let hotkeyHint = HotkeyManager.defaultShortcutDisplay
    let audioSettings: AudioSettingsStore

    private let dependencies: WhisperAppDependencies
    private var shouldInsertAfterRecording = true
    private var pendingInsertionTarget: TextInsertionService.Target?
    private var inputLevelTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var insertionWatchdogToken: UUID?
    private var hasPreparedModel = false
    private var isRunningStartupSetup = false
    private var recordingDeliveryMode: RecordingDeliveryMode = .uiPreviewThenFinalInsert
    private var streamingInsertionSession: TextInsertionService.StreamingSession?

    init(
        audioSettings: AudioSettingsStore,
        dependencies: WhisperAppDependencies? = nil,
        bootstrapsOnInit: Bool = true
    ) {
        let resolvedDependencies = dependencies ?? .live(audioSettings: audioSettings)
        self.audioSettings = audioSettings
        self.dependencies = resolvedDependencies
        self.permissions = resolvedDependencies.permissionSnapshot()
        self.codeSigningStatus = resolvedDependencies.codeSigningStatus()
        DebugLog.log(
            "WhisperAppState initialized. backend=\(AudioSettingsStore.transcriptionModelName) selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity)) autoCopy=\(audioSettings.automaticallyCopyTranscripts) pasteFallback=\(audioSettings.allowPasteFallback) audioCues=\(audioSettings.playAudioCues) streamingPreview=\(resolvedDependencies.isExperimentalStreamingPreviewEnabled())",
            category: "app"
        )

        installDefaultHotkeyListener()

        startPermissionRefreshLoop()

        if bootstrapsOnInit {
            Task {
                await bootstrap()
            }
        }
    }

    deinit {
        permissionRefreshTask?.cancel()
        inputLevelTask?.cancel()
        insertionWatchdogToken = nil
    }

    var statusTitle: String {
        if isRecording {
            return "Recording"
        }
        if isTranscribing {
            return "Transcribing"
        }
        if isInserting {
            return "Finishing"
        }
        switch startupSetupPhase {
        case .checkingSigning:
            return "Starting Up"
        case .preparingBackend:
            return "Preparing Model"
        case .requestingMicrophone, .requestingAccessibility:
            return "Permissions Needed"
        case .ready:
            return "Ready"
        case .failed(let failure):
            switch failure {
            case .unstableSigning:
                return "Signed Build Needed"
            case .backend:
                return "Setup Failed"
            case .microphonePermission, .accessibilityPermission:
                return "Permissions Needed"
            }
        }
    }

    var canRecord: Bool {
        if isRecording {
            return true
        }

        return startupSetupPhase.isReady && !isPreparingModel && !isTranscribing && !isInserting
    }

    var canUseGlobalTrigger: Bool {
        hotkeyListenerStatus.isInstalled
    }

    var hasRequiredWorkflowPermissions: Bool {
        permissions.microphone.isGranted && permissions.accessibility.isGranted
    }

    var hasStableSigningIdentity: Bool {
        codeSigningStatus.hasStableIdentity
    }

    var hotkeyShortcutSummary: String {
        switch hotkeyListenerStatus {
        case .installed:
            return "Shortcut: press \(hotkeyHint) once to start recording and again to transcribe"
        case .failedToRegister:
            return "Shortcut: reopen spk if \(hotkeyHint) still does not respond"
        case .inactive:
            return "Shortcut: checking \(hotkeyHint) setup"
        }
    }

    var hotkeySettingsSummary: String {
        switch hotkeyListenerStatus {
        case .installed:
            return "Only Microphone and Accessibility are required. \(hotkeyHint) starts recording and finishes the transcript."
        case .failedToRegister:
            return "Only Microphone and Accessibility are required. Reopen spk if \(hotkeyHint) still does not respond."
        case .inactive:
            return "Only Microphone and Accessibility are required. Checking whether \(hotkeyHint) is available."
        }
    }

    var hotkeySessionStateLabel: String {
        switch hotkeyListenerStatus {
        case .installed:
            return "Standing by"
        case .failedToRegister:
            return "Shortcut error"
        case .inactive:
            return "Checking"
        }
    }

    var transcriptionModeDescription: String {
        AudioSettingsStore.transcriptionSettingsDescription
    }

    var isExperimentalStreamingPreviewEnabled: Bool {
        dependencies.isExperimentalStreamingPreviewEnabled()
    }

    var signingStatusSummary: String {
        codeSigningStatus.hasStableIdentity
            ? "Stable signing identity: \(codeSigningStatus.statusLabel)."
            : codeSigningStatus.explanation
    }

    var setupSummary: String {
        switch startupSetupPhase {
        case .ready:
            return hasStableSigningIdentity ? hotkeySettingsSummary : signingStatusSummary
        case .failed(let failure):
            return failure.message
        case .checkingSigning, .preparingBackend, .requestingMicrophone, .requestingAccessibility:
            return statusMessage
        }
    }

    var shouldShowStartupReadinessProgress: Bool {
        !isRecording && !isTranscribing && !isInserting && !startupSetupPhase.isReady
    }

    var showsStartupSpinner: Bool {
        switch startupSetupPhase {
        case .checkingSigning, .preparingBackend, .requestingMicrophone, .requestingAccessibility:
            return true
        case .ready, .failed:
            return false
        }
    }

    var startupNeedsAttention: Bool {
        if case .failed = startupSetupPhase {
            return true
        }

        return false
    }

    var startupProgressTitle: String {
        "\(AudioSettingsStore.transcriptionDisplayName) readiness"
    }

    var startupProgressSummary: String {
        "\(startupCompletedChecklistCount) of \(startupChecklistItems.count) steps ready"
    }

    var startupProgressFraction: Double {
        guard !startupChecklistItems.isEmpty else { return 0 }
        return Double(startupCompletedChecklistCount) / Double(startupChecklistItems.count)
    }

    var shouldShowStreamingPreviewCard: Bool {
        isStreamingPreviewActive && isRecording
    }

    var streamingPreviewDisplayText: String {
        streamingPreviewText.isEmpty ? "Waiting for speech..." : streamingPreviewText
    }

    var startupCompletedChecklistCount: Int {
        startupChecklistItems.filter { $0.state == .complete }.count
    }

    var startupChecklistItems: [StartupChecklistItem] {
        [
            StartupChecklistItem(
                id: "signing",
                title: "Stable signed build",
                detail: hasStableSigningIdentity
                    ? "Installed with a team identity."
                    : "Needed to keep Accessibility stable across launches.",
                state: signingChecklistState
            ),
            StartupChecklistItem(
                id: "backend",
                title: "\(AudioSettingsStore.transcriptionDisplayName) backend",
                detail: modelReady
                    ? "Bundled or locally installed, validated, and ready."
                    : "Preparing the local-only model files.",
                state: backendChecklistState
            ),
            StartupChecklistItem(
                id: "microphone",
                title: "Microphone access",
                detail: permissions.microphone.isGranted
                    ? "Audio capture is available."
                    : "Required before dictation can start.",
                state: microphoneChecklistState
            ),
            StartupChecklistItem(
                id: "accessibility",
                title: "Accessibility access",
                detail: permissions.accessibility.isGranted
                    ? "spk can type into the focused app."
                    : "Required to insert dictated text.",
                state: accessibilityChecklistState
            )
        ]
    }

    func bootstrap() async {
        await runStartupSetupPipeline(reason: "bootstrap")
    }

    func refreshPermissions(reconcileStartupState: Bool = true) {
        permissions = dependencies.permissionSnapshot()
        let latestCodeSigningStatus = dependencies.codeSigningStatus()
        if latestCodeSigningStatus != codeSigningStatus {
            DebugLog.log(
                "Code signing status changed. signature=\(latestCodeSigningStatus.signature) team=\(latestCodeSigningStatus.teamIdentifier ?? "none") stable=\(latestCodeSigningStatus.hasStableIdentity)",
                category: "permissions"
            )
        }
        codeSigningStatus = latestCodeSigningStatus
        DebugLog.log(
            "Permissions refreshed. microphone=\(permissions.microphone.description) accessibility=\(permissions.accessibility.description)",
            category: "permissions"
        )

        if permissions.accessibility.isGranted {
            dependencies.setLastAccessibilityStartupPromptVersion(nil)
        }

        if reconcileStartupState {
            reconcileStartupStateIfPossible()
        } else {
            updateStatusMessage()
        }
    }

    func requestMicrophonePermission() async {
        _ = await dependencies.requestMicrophonePermission()
        refreshPermissions(reconcileStartupState: false)
        if permissions.microphone.isGranted {
            await runStartupSetupPipeline(reason: "manual-microphone-request")
        } else {
            startupSetupPhase = .failed(.microphonePermission(microphonePermissionRequiredMessage))
            updateStatusMessage()
        }
    }

    func requestAccessibilityPermission() {
        dependencies.setLastAccessibilityStartupPromptVersion(dependencies.bundleVersionIdentifier())
        dependencies.promptForAccessibilityPermission()
        startupSetupPhase = .failed(.accessibilityPermission(accessibilityPermissionRequiredMessage))
        DebugLog.log("Accessibility permission prompt requested from UI.", category: "permissions")
        refreshPermissions(reconcileStartupState: false)
        updateStatusMessage()
    }

    func openMicrophoneSettings() {
        dependencies.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        dependencies.openAccessibilitySettings()
    }

    @discardableResult
    func prepareModelIfNeeded(reconcileStartupState: Bool = true) async -> Bool {
        guard !isPreparingModel else {
            return hasPreparedModel
        }
        if hasPreparedModel {
            modelReady = true
            modelMessage = "Ready locally: \(AudioSettingsStore.transcriptionModelName)"
            if reconcileStartupState {
                reconcileStartupStateIfPossible()
            }
            return true
        }

        isPreparingModel = true
        if reconcileStartupState {
            startupSetupPhase = .preparingBackend
        }
        modelMessage = "Preparing \(AudioSettingsStore.transcriptionModelName)..."
        DebugLog.log("Preparing the Whisper transcription backend from bundled or locally installed model files.", category: "model")
        do {
            let preparation = try await dependencies.prepareTranscription()
            hasPreparedModel = true
            modelReady = true
            modelMessage = "Ready locally: \(preparation.readyDisplayName)"
            DebugLog.log("Whisper transcription backend ready at \(DebugLog.displayPath(preparation.resolvedModelURL))", category: "model")
            if reconcileStartupState {
                reconcileStartupStateIfPossible()
            } else {
                updateStatusMessage()
            }
        } catch {
            modelReady = hasPreparedModel
            modelMessage = "Model setup failed"
            DebugLog.log("Model preparation failed: \(error)", category: "model")
            if reconcileStartupState {
                startupSetupPhase = .failed(.backend(error.localizedDescription))
                updateStatusMessage()
            } else {
                statusMessage = error.localizedDescription
            }
            isPreparingModel = false
            return false
        }
        isPreparingModel = false
        return hasPreparedModel
    }

    func retryModelSetup() async {
        await runStartupSetupPipeline(reason: "manual-setup-retry")
    }

    func toggleRecordingFromButton() async {
        if isRecording {
            await finishRecording(insertIntoFocusedApp: shouldInsertAfterRecording)
        } else {
            await startRecording(trigger: .button, insertIntoFocusedApp: true)
        }
    }

    func openModelFolder() {
        Task {
            do {
                let folder = try await dependencies.modelDirectoryURL()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                DebugLog.log("Opening model folder at \(DebugLog.displayPath(folder))", category: "app")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                statusMessage = error.localizedDescription
                DebugLog.log("Failed to open model folder: \(error)", category: "app")
            }
        }
    }

    func chooseStreamingPreviewModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a local WhisperKit model folder for live preview."

        if let existingPath = audioSettings.experimentalStreamingModelFolderPath {
            panel.directoryURL = URL(fileURLWithPath: existingPath)
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        audioSettings.setExperimentalStreamingModelFolderURL(selectedURL)

        switch audioSettings.experimentalStreamingSetupStatus {
        case .ready(let resolvedModel):
            statusMessage = "Live preview will use \(resolvedModel.displayName) while recording."
        case .invalidCustomPath:
            statusMessage = "That folder does not look like a WhisperKit model."
        case .missingModel:
            statusMessage = "That folder does not contain a WhisperKit preview model."
        case .unsupportedHardware:
            statusMessage = "WhisperKit live preview currently requires Apple Silicon."
        case .disabled, .invalidEnvironmentPath:
            statusMessage = audioSettings.experimentalStreamingSummary
        }
    }

    func clearStreamingPreviewModelFolder() {
        audioSettings.clearExperimentalStreamingModelFolder()
        statusMessage = audioSettings.experimentalStreamingSummary
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        dependencies.copyTextToClipboard(lastTranscript)
        statusMessage = "Copied transcript to the clipboard."
    }

    func copyDebugLog() {
        do {
            try DebugLog.copyToPasteboard()
            statusMessage = "Copied diagnostics to the clipboard."
            DebugLog.log("Copied in-memory diagnostics to pasteboard.", category: "diagnostics")
        } catch {
            if let debugLogError = error as? DebugLog.DebugLogError, debugLogError == .disabled {
                statusMessage = debugLogError.localizedDescription
            } else {
                statusMessage = "Could not copy diagnostics."
                DebugLog.log("Failed to copy diagnostics: \(error)", category: "diagnostics")
            }
        }
    }

    func exportDebugLog() {
        do {
            let exportURL = try DebugLog.exportInteractively()
            statusMessage = "Exported diagnostics."
            DebugLog.log("Exported diagnostics to \(DebugLog.displayPath(exportURL)).", category: "diagnostics")
        } catch {
            if let debugLogError = error as? DebugLog.DebugLogError, debugLogError == .exportCancelled {
                statusMessage = debugLogError.localizedDescription
                DebugLog.log("Diagnostics export was cancelled.", category: "diagnostics")
            } else if let debugLogError = error as? DebugLog.DebugLogError, debugLogError == .disabled {
                statusMessage = debugLogError.localizedDescription
            } else {
                statusMessage = "Could not export diagnostics."
                DebugLog.log("Failed to export diagnostics: \(error)", category: "diagnostics")
            }
        }
    }

    var debugLogPath: String {
        DebugLog.exportStatusDescription()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func handleHotkeyToggle() async {
        if isRecording {
            await finishRecording(insertIntoFocusedApp: true)
            return
        }

        guard canUseGlobalTrigger else {
            statusMessage = hotkeyUnavailableStatusMessage
            DebugLog.log(
                "Hotkey toggle ignored because the default shortcut is unavailable. status=\(hotkeyListenerStatus.logDescription)",
                category: "app"
            )
            return
        }

        guard canRecord else {
            statusMessage = busyHotkeyStatusMessage
            DebugLog.log("Hotkey toggle ignored because the app is busy.", category: "app")
            return
        }

        await startRecording(trigger: .hotkey, insertIntoFocusedApp: true)
    }

    private func startRecording(trigger: RecordingTrigger, insertIntoFocusedApp: Bool) async {
        guard !isPreparingModel, !isTranscribing, !isInserting else {
            if trigger == .hotkey {
                statusMessage = busyHotkeyStatusMessage
                DebugLog.log("Start recording blocked: hotkey pressed while the app was busy.", category: "app")
            }
            return
        }

        if insertIntoFocusedApp {
            pendingInsertionTarget = dependencies.captureInsertionTarget()
        } else {
            pendingInsertionTarget = nil
        }

        let deliveryDecision = resolvedRecordingDeliveryDecision(
            for: trigger,
            insertIntoFocusedApp: insertIntoFocusedApp,
            pendingInsertionTarget: pendingInsertionTarget
        )
        recordingDeliveryMode = deliveryDecision.mode
        DebugLog.log(
            "Start recording requested. trigger=\(trigger.logDescription) deliveryMode=\(recordingDeliveryMode.logDescription) deliveryReason=\(deliveryDecision.reason) capturedTarget=\(describeRecordingTargetForDiagnostics(pendingInsertionTarget)) spkWindowsVisible=\(deliveryDecision.hasVisibleSpkWindows) insert=\(insertIntoFocusedApp) selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity))",
            category: "app"
        )
        streamingInsertionSession = nil

        if trigger == .hotkey && !canUseGlobalTrigger {
            statusMessage = hotkeyUnavailableStatusMessage
            DebugLog.log(
                "Start recording blocked: default shortcut unavailable. status=\(hotkeyListenerStatus.logDescription)",
                category: "app"
            )
            return
        }

        if !startupSetupPhase.isReady {
            DebugLog.log(
                "Start recording paused because startup setup is incomplete. phase=\(String(describing: startupSetupPhase))",
                category: "app"
            )
            await runStartupSetupPipeline(reason: "recording-start")
            guard startupSetupPhase.isReady else { return }
        }

        do {
            playAudioCueIfEnabled(.recordingWillStart)
            let requestedStreamingPreview = dependencies.isExperimentalStreamingPreviewEnabled()
            isStreamingPreviewActive = try await dependencies.audioStart(audioSettings.selectedInputDeviceID)
            let previewUnavailableReason: String?
            if requestedStreamingPreview, !isStreamingPreviewActive {
                previewUnavailableReason = await dependencies.streamingPreviewUnavailableReason()
            } else {
                previewUnavailableReason = nil
            }
            shouldInsertAfterRecording = insertIntoFocusedApp
            isRecording = true
            streamingPreviewText = isStreamingPreviewActive ? "Waiting for speech..." : ""
            statusMessage = initialListeningStatusMessage(
                insertIntoFocusedApp: insertIntoFocusedApp,
                livePreviewUnavailableReason: previewUnavailableReason
            )
            primeStreamingInsertionSessionIfNeeded()
            startInputLevelMonitoring()
            DebugLog.log(
                "Recording started. deliveryMode=\(recordingDeliveryMode.logDescription) liveInsertionPrimed=\(streamingInsertionSession != nil) livePreviewActive=\(isStreamingPreviewActive) livePreviewRequested=\(requestedStreamingPreview) livePreviewUnavailableReason=\(previewUnavailableReason ?? "none")",
                category: "app"
            )
        } catch {
            statusMessage = error.localizedDescription
            liveInputLevel = 0
            isStreamingPreviewActive = false
            streamingPreviewText = ""
            recordingDeliveryMode = .uiPreviewThenFinalInsert
            pendingInsertionTarget = nil
            DebugLog.log("Recording start failed: \(error)", category: "app")
        }
    }

    private func finishRecording(insertIntoFocusedApp: Bool) async {
        guard isRecording else { return }

        defer {
            insertionWatchdogToken = nil
            pendingInsertionTarget = nil
            isTranscribing = false
            isInserting = false
            recordingDeliveryMode = .uiPreviewThenFinalInsert
            streamingInsertionSession = nil
            DebugLog.log(
                "Reset transient recording state. recording=\(isRecording) transcribing=\(isTranscribing) inserting=\(isInserting)",
                category: "app"
            )
        }

        let stopResult = await dependencies.audioStop()
        isRecording = false
        stopInputLevelMonitoring()
        isStreamingPreviewActive = false
        streamingPreviewText = ""
        playAudioCueIfEnabled(.recordingDidStop)

        guard stopResult.recordingURL != nil || stopResult.bufferedSamples != nil else {
            cancelStreamingInsertionIfNeeded()
            statusMessage = "The recording did not produce an audio file."
            DebugLog.log("Recording produced no file.", category: "app")
            return
        }

        if let recordingURL = stopResult.recordingURL {
            DebugLog.log("Recording stopped. file=\(DebugLog.displayPath(recordingURL))", category: "app")
        } else if let bufferedSamples = stopResult.bufferedSamples {
            DebugLog.log("Recording stopped with buffered samples. count=\(bufferedSamples.count)", category: "app")
        }

        isTranscribing = true
        statusMessage = "Preparing audio for transcription..."

        do {
            DebugLog.log("Preparing recorded audio for transcription on a background task.", category: "app")
            let preparedRecording: PreparedRecording
            if let bufferedSamples = stopResult.bufferedSamples {
                preparedRecording = try await dependencies.prepareSamplesForTranscription(
                    bufferedSamples,
                    audioSettings.inputSensitivity
                )
            } else if let recordingURL = stopResult.recordingURL {
                preparedRecording = try await dependencies.prepareRecordingForTranscription(
                    recordingURL,
                    audioSettings.inputSensitivity
                )
            } else {
                statusMessage = "The recording did not produce audio samples."
                DebugLog.log("Recording produced neither a file nor buffered samples.", category: "app")
                return
            }

            if preparedRecording.duration < 0.3 {
                cancelStreamingInsertionIfNeeded()
                statusMessage = "Recording too short. Speak a little longer before stopping."
                DebugLog.log("Recording rejected because duration was too short.", category: "app")
                return
            }

            if preparedRecording.rmsLevel < 0.001 {
                cancelStreamingInsertionIfNeeded()
                statusMessage = "No audio signal received. Check microphone and input level."
                DebugLog.log("Recording rejected because RMS was below threshold.", category: "app")
                return
            }

            statusMessage = "Finalizing \(AudioSettingsStore.transcriptionDisplayName)..."
            DebugLog.log("Finalizing transcript with the Whisper pipeline.", category: "app")

            let text = try await dependencies.transcribePreparedRecording(preparedRecording.samples)
            let trimmedText = normalizeTranscript(text)

            DebugLog.log("Transcription completed. trimmedLength=\(trimmedText.count)", category: "app")

            guard !trimmedText.isEmpty else {
                cancelStreamingInsertionIfNeeded()
                statusMessage = "No speech was detected in the recording."
                DebugLog.log(
                    "The selected transcription backend returned an empty transcript for non-silent audio. Treating this as a transcription/decode issue.",
                    category: "app"
                )
                return
            }

            lastTranscript = trimmedText
            isTranscribing = false
            isInserting = true
            statusMessage = "Finalizing transcript..."

            let autoCopyEnabled = audioSettings.automaticallyCopyTranscripts

            if insertIntoFocusedApp {
                let insertionOptions = TextInsertionService.InsertionOptions(
                    restoreClipboardAfterPaste: !autoCopyEnabled,
                    copyToClipboardOnFailure: autoCopyEnabled,
                    allowPasteFallback: audioSettings.allowPasteFallback
                )
                scheduleInsertionWatchdog(transcript: trimmedText, autoCopyEnabled: autoCopyEnabled)
                let insertionOutcome: TextInsertionService.InsertionOutcome
                if let streamingInsertionSession {
                    insertionOutcome = dependencies.commitStreamingInsertionSession(
                        streamingInsertionSession,
                        trimmedText,
                        insertionOptions
                    )
                    self.streamingInsertionSession = nil
                } else {
                    insertionOutcome = dependencies.insertText(trimmedText, pendingInsertionTarget, insertionOptions)
                }
                let transcriptAlreadyOnClipboard = insertionOutcome == .copiedToClipboardAfterFailure ||
                    (autoCopyEnabled && insertionOutcome == .insertedPaste)

                if autoCopyEnabled && !transcriptAlreadyOnClipboard {
                    dependencies.copyTextToClipboard(trimmedText)
                }

                statusMessage = insertionOutcome.statusMessage(autoCopied: autoCopyEnabled)
                DebugLog.log(
                    "Transcript insertion outcome: \(insertionOutcome.logDescription) autoCopy=\(autoCopyEnabled)",
                    category: "app"
                )
            } else {
                if autoCopyEnabled {
                    dependencies.copyTextToClipboard(trimmedText)
                    statusMessage = "Transcription ready and copied to the clipboard."
                } else {
                    statusMessage = "Transcription ready."
                }
                DebugLog.log("Transcript ready without insertion. autoCopy=\(autoCopyEnabled)", category: "app")
            }

            playAudioCueIfEnabled(.pipelineDidComplete)
        } catch {
            cancelStreamingInsertionIfNeeded()
            statusMessage = error.localizedDescription
            DebugLog.log("Transcription flow failed: \(error)", category: "app")
        }
    }

    private func scheduleInsertionWatchdog(transcript: String, autoCopyEnabled: Bool) {
        let token = UUID()
        insertionWatchdogToken = token

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.insertionWatchdogDelay) { [weak self] in
            guard let self else { return }
            guard self.insertionWatchdogToken == token, self.isInserting else { return }

            DebugLog.log(
                "Insertion watchdog fired after \(String(format: "%.1f", Self.insertionWatchdogDelay))s. Resetting insertion UI state.",
                category: "app"
            )

            self.isInserting = false
            self.pendingInsertionTarget = nil
            self.insertionWatchdogToken = nil

            if self.statusMessage == "Finalizing transcript..." {
                if autoCopyEnabled {
                    self.dependencies.copyTextToClipboard(transcript)
                    self.statusMessage = "Copied transcript to the clipboard. If it didn't paste, paste it manually."
                } else {
                    self.statusMessage = "Transcription ready. If it didn't paste, use Copy."
                }
            }
        }
    }

    private func initialListeningStatusMessage(
        insertIntoFocusedApp: Bool,
        livePreviewUnavailableReason: String? = nil
    ) -> String {
        let baseMessage: String
        if insertIntoFocusedApp {
            baseMessage = "Recording... spk will insert the transcript when you stop."
        } else {
            baseMessage = "Recording..."
        }

        guard let livePreviewUnavailableReason else {
            return baseMessage
        }

        if insertIntoFocusedApp {
            return "\(baseMessage) Live preview unavailable. The final transcript will still insert when you stop. \(livePreviewUnavailableReason)"
        }

        return "\(baseMessage) Live preview unavailable. \(livePreviewUnavailableReason)"
    }

    private func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startInputLevelMonitoring() {
        inputLevelTask?.cancel()
        liveInputLevel = 0
        streamingPreviewText = isStreamingPreviewActive ? "Waiting for speech..." : ""
        inputLevelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                let rawLevel = await self.dependencies.normalizedInputLevel()
                let smoothedLevel = max(Double(rawLevel), self.liveInputLevel * 0.82)
                self.liveInputLevel = min(max(smoothedLevel, 0), 1)
                if self.isStreamingPreviewActive,
                   let previewSnapshot = await self.dependencies.streamingPreviewSnapshot() {
                    self.streamingPreviewText = previewSnapshot.displayText.isEmpty
                        ? "Waiting for speech..."
                        : previewSnapshot.displayText
                    self.pushStreamingPreviewIntoFocusedAppIfNeeded(previewSnapshot)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func stopInputLevelMonitoring() {
        inputLevelTask?.cancel()
        inputLevelTask = nil
        liveInputLevel = 0
        isStreamingPreviewActive = false
        streamingPreviewText = ""
    }

    private func pushStreamingPreviewIntoFocusedAppIfNeeded(
        _ previewSnapshot: StreamingPreviewSnapshot
    ) {
        guard shouldInsertAfterRecording, recordingDeliveryMode == .liveExternalInsert else { return }
        let previewText = liveStreamingInsertionText(from: previewSnapshot)
        guard !previewText.isEmpty else { return }
        primeStreamingInsertionSessionIfNeeded()
        guard let streamingInsertionSession else { return }
        _ = dependencies.updateStreamingInsertionSession(streamingInsertionSession, previewText)
    }

    private func cancelStreamingInsertionIfNeeded() {
        guard let streamingInsertionSession else { return }
        dependencies.cancelStreamingInsertionSession(streamingInsertionSession)
        self.streamingInsertionSession = nil
    }

    private func liveStreamingInsertionText(
        from previewSnapshot: StreamingPreviewSnapshot
    ) -> String {
        let previewText = previewSnapshot.displayText
        switch previewText {
        case "", "Waiting for speech...", "Live preview unavailable.":
            return ""
        default:
            return previewText
        }
    }

    private func primeStreamingInsertionSessionIfNeeded() {
        guard shouldInsertAfterRecording, recordingDeliveryMode == .liveExternalInsert else { return }
        guard streamingInsertionSession == nil else { return }
        guard let pendingInsertionTarget else {
            DebugLog.log("Skipped live insertion priming because no external insertion target was captured.", category: "app")
            return
        }

        streamingInsertionSession = dependencies.beginStreamingInsertionSession(pendingInsertionTarget)
        DebugLog.log(
            "Primed live insertion session. target=\(describeRecordingTargetForDiagnostics(pendingInsertionTarget)) success=\(streamingInsertionSession != nil)",
            category: "app"
        )
    }

    private func resolvedRecordingDeliveryDecision(
        for trigger: RecordingTrigger,
        insertIntoFocusedApp: Bool,
        pendingInsertionTarget: TextInsertionService.Target?
    ) -> RecordingDeliveryDecision {
        let hasVisibleSpkWindows = dependencies.hasVisibleSpkWindows()

        guard insertIntoFocusedApp else {
            return RecordingDeliveryDecision(
                mode: .uiPreviewThenFinalInsert,
                reason: "insertion-disabled",
                hasVisibleSpkWindows: hasVisibleSpkWindows
            )
        }

        guard trigger == .hotkey else {
            return RecordingDeliveryDecision(
                mode: .uiPreviewThenFinalInsert,
                reason: "button-trigger",
                hasVisibleSpkWindows: hasVisibleSpkWindows
            )
        }

        guard isRecoverableExternalInsertionTarget(pendingInsertionTarget) else {
            return RecordingDeliveryDecision(
                mode: .uiPreviewThenFinalInsert,
                reason: "no-recoverable-external-hotkey-target",
                hasVisibleSpkWindows: hasVisibleSpkWindows
            )
        }

        return RecordingDeliveryDecision(
            mode: .liveExternalInsert,
            reason: "captured-external-hotkey-target",
            hasVisibleSpkWindows: hasVisibleSpkWindows
        )
    }

    private func isRecoverableExternalInsertionTarget(
        _ target: TextInsertionService.Target?
    ) -> Bool {
        guard let target else { return false }
        return target.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func describeRecordingTargetForDiagnostics(
        _ target: TextInsertionService.Target?
    ) -> String {
        guard let target else { return "none" }
        return "\(DebugLog.displayApplicationName(target.applicationName)) pid=\(DebugLog.displayProcessIdentifier(target.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(target.bundleIdentifier))"
    }

    private func startPermissionRefreshLoop() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let latestPermissions = self.dependencies.permissionSnapshot()
                let latestCodeSigningStatus = self.dependencies.codeSigningStatus()
                if latestPermissions.microphone.isGranted != self.permissions.microphone.isGranted ||
                    latestPermissions.accessibility.isGranted != self.permissions.accessibility.isGranted ||
                    latestPermissions.microphone.description != self.permissions.microphone.description ||
                    latestPermissions.accessibility.description != self.permissions.accessibility.description ||
                    latestCodeSigningStatus != self.codeSigningStatus {
                    DebugLog.log(
                        "Runtime state changed. microphone=\(latestPermissions.microphone.description) accessibility=\(latestPermissions.accessibility.description) signature=\(latestCodeSigningStatus.signature) team=\(latestCodeSigningStatus.teamIdentifier ?? "none") stable=\(latestCodeSigningStatus.hasStableIdentity)",
                        category: "permissions"
                    )
                    self.permissions = latestPermissions
                    self.codeSigningStatus = latestCodeSigningStatus
                    if latestPermissions.accessibility.isGranted {
                        self.dependencies.setLastAccessibilityStartupPromptVersion(nil)
                    }
                    if !self.isRunningStartupSetup && !self.startupSetupPhase.isReady && !self.isRecording && !self.isTranscribing && !self.isInserting {
                        Task { @MainActor [weak self] in
                            await self?.runStartupSetupPipeline(reason: "runtime-state-change")
                        }
                    } else {
                        self.reconcileStartupStateIfPossible()
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusMessage() {
        if isRecording || isTranscribing || isInserting {
            return
        }

        switch startupSetupPhase {
        case .checkingSigning:
            statusMessage = "Checking your installed build identity and startup setup."
        case .preparingBackend:
            statusMessage = "Preparing \(AudioSettingsStore.transcriptionModelName) from bundled or locally installed files."
        case .requestingMicrophone:
            statusMessage = "Requesting microphone access so spk can finish startup."
        case .requestingAccessibility:
            statusMessage = "Approve Accessibility access in System Settings, then return here."
        case .ready:
            statusMessage = canUseGlobalTrigger
                ? "Press \(hotkeyHint) once to start recording. Press it again to transcribe and insert the result."
                : hotkeyUnavailableStatusMessage
        case .failed(let failure):
            statusMessage = failure.message
        }
    }

    private func runStartupSetupPipeline(reason: String) async {
        guard !isRunningStartupSetup else { return }
        isRunningStartupSetup = true
        DebugLog.log("Bootstrapping startup setup. reason=\(reason)", category: "app")

        defer {
            isRunningStartupSetup = false
        }

        startupSetupPhase = .checkingSigning
        updateStatusMessage()
        refreshPermissions(reconcileStartupState: false)

        guard hasStableSigningIdentity else {
            startupSetupPhase = .failed(.unstableSigning(codeSigningStatus.readyWarning))
            updateStatusMessage()
            return
        }

        startupSetupPhase = .preparingBackend
        updateStatusMessage()
        guard await prepareModelIfNeeded(reconcileStartupState: false) else {
            startupSetupPhase = .failed(.backend(statusMessage))
            updateStatusMessage()
            return
        }

        refreshPermissions(reconcileStartupState: false)

        if !permissions.microphone.isGranted {
            if permissions.microphone.canRequestDirectly {
                startupSetupPhase = .requestingMicrophone
                updateStatusMessage()
                _ = await dependencies.requestMicrophonePermission()
                refreshPermissions(reconcileStartupState: false)
            }
        }

        if !permissions.accessibility.isGranted {
            let currentBuildVersionIdentifier = dependencies.bundleVersionIdentifier()
            if dependencies.lastAccessibilityStartupPromptVersion() != currentBuildVersionIdentifier {
                startupSetupPhase = .requestingAccessibility
                updateStatusMessage()
                dependencies.setLastAccessibilityStartupPromptVersion(currentBuildVersionIdentifier)
                dependencies.promptForAccessibilityPermission()
                refreshPermissions(reconcileStartupState: false)
            }
        }

        if !permissions.microphone.isGranted {
            startupSetupPhase = .failed(.microphonePermission(microphonePermissionRequiredMessage))
            updateStatusMessage()
            return
        }

        if !permissions.accessibility.isGranted {
            startupSetupPhase = .failed(.accessibilityPermission(accessibilityPermissionRequiredMessage))
            updateStatusMessage()
            return
        }

        startupSetupPhase = .ready
        updateStatusMessage()
    }

    private func reconcileStartupStateIfPossible() {
        guard !isRunningStartupSetup, !isRecording, !isTranscribing, !isInserting else { return }

        if !hasStableSigningIdentity {
            startupSetupPhase = .failed(.unstableSigning(codeSigningStatus.readyWarning))
            updateStatusMessage()
            return
        }

        if !modelReady {
            if case .failed(.backend) = startupSetupPhase {
                updateStatusMessage()
            } else if case .preparingBackend = startupSetupPhase {
                updateStatusMessage()
            } else {
                startupSetupPhase = .checkingSigning
                updateStatusMessage()
            }
            return
        }

        if !permissions.microphone.isGranted {
            startupSetupPhase = .failed(.microphonePermission(microphonePermissionRequiredMessage))
            updateStatusMessage()
            return
        }

        if !permissions.accessibility.isGranted {
            startupSetupPhase = .failed(.accessibilityPermission(accessibilityPermissionRequiredMessage))
            updateStatusMessage()
            return
        }

        startupSetupPhase = .ready
        updateStatusMessage()
    }

    private var microphonePermissionRequiredMessage: String {
        if permissions.microphone.needsSystemSettings {
            return "Microphone access is required before spk can finish startup. Open System Settings and allow microphone access."
        }

        return "Microphone access is required before spk can finish startup."
    }

    private var accessibilityPermissionRequiredMessage: String {
        "Accessibility access is required before spk can finish startup and type into other apps. Approve it in System Settings, then return here."
    }

    @discardableResult
    private func installDefaultHotkeyListener(forceReset: Bool = false) -> HotkeyManager.ListenerStatus {
        if forceReset {
            _ = dependencies.resetDefaultHotkey()
        }

        let listenerStatus = dependencies.installDefaultHotkey { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleHotkeyToggle()
            }
        }
        hotkeyListenerStatus = listenerStatus
        DebugLog.log(
            "Default shortcut status updated to \(listenerStatus.logDescription).",
            category: "hotkey"
        )
        return listenerStatus
    }

    private var hotkeyUnavailableStatusMessage: String {
        switch hotkeyListenerStatus {
        case .installed:
            return "Press \(hotkeyHint) once to start recording. Press it again to transcribe and insert the result."
        case .failedToRegister:
            return "Use the button to dictate now. spk could not register \(hotkeyHint); reopen spk and try again."
        case .inactive:
            return "Checking \(hotkeyHint) setup..."
        }
    }

    private var busyHotkeyStatusMessage: String {
        if isPreparingModel {
            return "\(AudioSettingsStore.transcriptionDisplayName) is still getting ready. Press \(hotkeyHint) again in a moment."
        }
        if isTranscribing {
            return "spk is still transcribing. Press \(hotkeyHint) again after the current transcript finishes."
        }
        if isInserting {
            return "spk is still delivering the current transcript. Press \(hotkeyHint) again in a moment."
        }
        return "spk is busy right now. Press \(hotkeyHint) again in a moment."
    }

    private func playAudioCueIfEnabled(_ cue: AudioCue) {
        guard audioSettings.playAudioCues else { return }
        dependencies.playAudioCue(cue)
    }

    private var signingChecklistState: StartupChecklistItemState {
        if hasStableSigningIdentity {
            return .complete
        }
        if case .failed(.unstableSigning) = startupSetupPhase {
            return .blocked
        }
        if case .checkingSigning = startupSetupPhase {
            return .active
        }
        return .pending
    }

    private var backendChecklistState: StartupChecklistItemState {
        if modelReady {
            return .complete
        }
        if case .failed(.backend) = startupSetupPhase {
            return .blocked
        }
        if isPreparingModel {
            return .active
        }
        if case .preparingBackend = startupSetupPhase {
            return .active
        }
        if !hasStableSigningIdentity {
            return .pending
        }
        return .pending
    }

    private var microphoneChecklistState: StartupChecklistItemState {
        if permissions.microphone.isGranted {
            return .complete
        }
        if case .requestingMicrophone = startupSetupPhase {
            return .active
        }
        if case .failed(.microphonePermission) = startupSetupPhase {
            return .blocked
        }
        if !hasStableSigningIdentity || !modelReady {
            return .pending
        }
        return permissions.microphone.canRequestDirectly ? .active : .blocked
    }

    private var accessibilityChecklistState: StartupChecklistItemState {
        if permissions.accessibility.isGranted {
            return .complete
        }
        if case .requestingAccessibility = startupSetupPhase {
            return .active
        }
        if case .failed(.accessibilityPermission) = startupSetupPhase {
            return .blocked
        }
        if !hasStableSigningIdentity || !modelReady || !permissions.microphone.isGranted {
            return .pending
        }
        return .blocked
    }
}
