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
    let audioStart: (String?) async throws -> Void
    let audioStop: () async -> RecordingStopResult
    let takeLiveSamples: () async -> [Float]
    let normalizedInputLevel: () async -> Float
    let prepareTranscription: () async throws -> TranscriptionPreparation
    let modelDirectoryURL: () async throws -> URL
    let startTranscriptionSession: () async throws -> Void
    let enqueueStreamingSamples: ([Float]) async throws -> Void
    let takeStreamingUpdate: () async throws -> StreamingTranscriptionUpdate?
    let finalizeTranscriptionSession: ([Float], [Float]?) async throws -> String
    let cancelTranscriptionSession: () async -> Void
    let prepareRecordingForTranscription: (URL, Double) async throws -> PreparedRecording
    let captureInsertionTarget: () -> TextInsertionService.Target?
    let insertText: (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome
    let beginLiveInsertion: (TextInsertionService.Target?) -> Bool
    let appendLiveInsertionText: (String) -> Bool
    let finalizeLiveInsertion: (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome
    let cancelLiveInsertion: () -> Void
    let copyTextToClipboard: (String) -> Void
    let playAudioCue: (AudioCue) -> Void

    static func live(
        audioSettings: AudioSettingsStore,
        permissionsManager: PermissionsManager = PermissionsManager(),
        audioRecorder: AudioRecorder = AudioRecorder(),
        whisperBridge: WhisperBridge = WhisperBridge(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        hotkeyManager: HotkeyManager = HotkeyManager(),
        audioCuePlayer: AudioCuePlayer = AudioCuePlayer()
    ) -> Self {
        let userDefaults = UserDefaults.standard
        let accessibilityPromptDefaultsKey = "startup.accessibilityPromptVersion"
        let transcriptionCoordinator = TranscriptionCoordinator(whisperBridge: whisperBridge)

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
                try await audioRecorder.start(preferredInputDeviceID: preferredInputDeviceID)
            },
            audioStop: {
                await audioRecorder.stop()
            },
            takeLiveSamples: {
                await audioRecorder.takeLiveSamples()
            },
            normalizedInputLevel: {
                await audioRecorder.normalizedInputLevel()
            },
            prepareTranscription: {
                try await transcriptionCoordinator.prepare()
            },
            modelDirectoryURL: {
                try await transcriptionCoordinator.modelDirectoryURL()
            },
            startTranscriptionSession: {
                try await transcriptionCoordinator.startStreaming()
            },
            enqueueStreamingSamples: { samples in
                try await transcriptionCoordinator.enqueueStreamingSamples(samples)
            },
            takeStreamingUpdate: {
                try await transcriptionCoordinator.takeStreamingUpdate()
            },
            finalizeTranscriptionSession: { trailingSamples, fallbackFinalSamples in
                try await transcriptionCoordinator.finalizeStreaming(
                    trailingSamples: trailingSamples,
                    fallbackFinalSamples: fallbackFinalSamples
                )
            },
            cancelTranscriptionSession: {
                await transcriptionCoordinator.cancelStreaming()
            },
            prepareRecordingForTranscription: { url, inputSensitivity in
                try await Task.detached(priority: .userInitiated) {
                    try AudioRecorder.prepareForTranscription(from: url, inputSensitivity: inputSensitivity)
                }.value
            },
            captureInsertionTarget: {
                textInsertionService.captureInsertionTarget()
            },
            insertText: { text, target, options in
                textInsertionService.insert(text, target: target, options: options)
            },
            beginLiveInsertion: { target in
                textInsertionService.beginLiveDictation(target: target)
            },
            appendLiveInsertionText: { text in
                textInsertionService.appendLiveText(text)
            },
            finalizeLiveInsertion: { text, target, options in
                textInsertionService.finalizeLiveDictation(text, target: target, options: options)
            },
            cancelLiveInsertion: {
                textInsertionService.cancelLiveDictation()
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
    private static let liveTranscriptStabilityGuardWords = 2

    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isInserting = false
    @Published private(set) var modelReady = false
    @Published private(set) var statusMessage = "Starting up..."
    @Published private(set) var modelMessage = "Checking transcription backend..."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var liveTranscriptPreview = ""
    @Published private(set) var permissions = PermissionSnapshot.current()
    @Published private(set) var codeSigningStatus = CodeSigningStatus.current()
    @Published private(set) var liveInputLevel: Double = 0
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
    private var liveStreamingTask: Task<Void, Never>?
    private var committedLiveTranscript = ""
    private var previousLivePartialTranscript = ""
    private var liveInsertionActive = false
    private var liveInsertionWindowDismissed = false
    private var didCommitLiveTranscriptDelta = false
    private var hasPreparedModel = false
    private var isRunningStartupSetup = false

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
            "WhisperAppState initialized. backend=\(AudioSettingsStore.transcriptionModelName) selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity)) autoCopy=\(audioSettings.automaticallyCopyTranscripts) audioCues=\(audioSettings.playAudioCues)",
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
        liveStreamingTask?.cancel()
        insertionWatchdogToken = nil
        dependencies.cancelLiveInsertion()
        let cancelTranscriptionSession = dependencies.cancelTranscriptionSession
        Task {
            await cancelTranscriptionSession()
        }
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
            return "Shortcut: press \(hotkeyHint) once to start live dictation and again to finish"
        case .failedToRegister:
            return "Shortcut: reopen spk if \(hotkeyHint) still does not respond"
        case .inactive:
            return "Shortcut: checking \(hotkeyHint) setup"
        }
    }

    var hotkeySettingsSummary: String {
        switch hotkeyListenerStatus {
        case .installed:
            return "Only Microphone and Accessibility are required. \(hotkeyHint) starts live dictation and finishes the transcript."
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
                    ? "Downloaded, validated, and ready."
                    : "Preparing the local model.",
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
            modelMessage = "Ready: \(AudioSettingsStore.transcriptionModelName)"
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
        DebugLog.log("Preparing the Whisper transcription backend.", category: "model")
        do {
            let preparation = try await dependencies.prepareTranscription()
            hasPreparedModel = true
            modelReady = true
            modelMessage = "Ready: \(preparation.readyDisplayName)"
            DebugLog.log("Whisper transcription backend ready at \(preparation.resolvedModelURL.path)", category: "model")
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
            await startRecording(trigger: "button", insertIntoFocusedApp: true)
        }
    }

    func openModelFolder() {
        Task {
            do {
                let folder = try await dependencies.modelDirectoryURL()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                DebugLog.log("Opening model folder at \(folder.path)", category: "app")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                statusMessage = error.localizedDescription
                DebugLog.log("Failed to open model folder: \(error)", category: "app")
            }
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        dependencies.copyTextToClipboard(lastTranscript)
        statusMessage = "Copied transcript to the clipboard."
    }

    func copyDebugLog() {
        do {
            try DebugLog.copyToPasteboard()
            statusMessage = "Copied debug log to the clipboard."
            DebugLog.log("Copied debug log to pasteboard.", category: "diagnostics")
        } catch {
            statusMessage = "Could not copy the debug log."
            DebugLog.log("Failed to copy debug log: \(error)", category: "diagnostics")
        }
    }

    func revealDebugLog() {
        do {
            try DebugLog.revealInFinder()
            statusMessage = "Opened the debug log in Finder."
            DebugLog.log("Revealed debug log in Finder.", category: "diagnostics")
        } catch {
            statusMessage = "Could not open the debug log."
            DebugLog.log("Failed to reveal debug log: \(error)", category: "diagnostics")
        }
    }

    var debugLogPath: String {
        DebugLog.logFilePath()
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

        await startRecording(trigger: "hotkey", insertIntoFocusedApp: true)
    }

    private func startRecording(trigger: String, insertIntoFocusedApp: Bool) async {
        guard !isPreparingModel, !isTranscribing, !isInserting else {
            if trigger == "fn" {
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

        DebugLog.log(
            "Start recording requested. trigger=\(trigger) insert=\(insertIntoFocusedApp) selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity))",
            category: "app"
        )

        if trigger == "hotkey" && !canUseGlobalTrigger {
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
            try await dependencies.audioStart(audioSettings.selectedInputDeviceID)
            shouldInsertAfterRecording = insertIntoFocusedApp
            resetLiveTranscriptionState()
            isRecording = true
            liveInsertionActive = insertIntoFocusedApp ? dependencies.beginLiveInsertion(pendingInsertionTarget) : false
            statusMessage = initialListeningStatusMessage(
                insertIntoFocusedApp: insertIntoFocusedApp,
                liveInsertionActive: liveInsertionActive
            )
            startInputLevelMonitoring()
            startLiveStreaming(insertIntoFocusedApp: insertIntoFocusedApp)
            DebugLog.log("Recording started.", category: "app")
        } catch {
            await dependencies.cancelTranscriptionSession()
            statusMessage = error.localizedDescription
            liveInputLevel = 0
            DebugLog.log("Recording start failed: \(error)", category: "app")
        }
    }

    private func finishRecording(insertIntoFocusedApp: Bool) async {
        guard isRecording else { return }
        var finalizedTranscriptionSession = false

        defer {
            insertionWatchdogToken = nil
            pendingInsertionTarget = nil
            isTranscribing = false
            isInserting = false
            resetLiveTranscriptionState()
            dependencies.cancelLiveInsertion()
            DebugLog.log(
                "Reset transient recording state. recording=\(isRecording) transcribing=\(isTranscribing) inserting=\(isInserting)",
                category: "app"
            )
        }

        let stopResult = await dependencies.audioStop()
        isRecording = false
        stopInputLevelMonitoring()
        await stopLiveStreaming()
        playAudioCueIfEnabled(.recordingDidStop)

        let recordingURL = stopResult.recordingURL
        guard let recordingURL else {
            await dependencies.cancelTranscriptionSession()
            statusMessage = "The recording did not produce an audio file."
            DebugLog.log("Recording produced no file.", category: "app")
            return
        }

        DebugLog.log("Recording stopped. file=\(recordingURL.path)", category: "app")

        isTranscribing = true
        statusMessage = "Preparing audio for transcription..."

        do {
            DebugLog.log("Preparing recorded audio for transcription on a background task.", category: "app")
            let preparedRecording = try await dependencies.prepareRecordingForTranscription(
                recordingURL,
                audioSettings.inputSensitivity
            )

            if preparedRecording.duration < 0.3 {
                await dependencies.cancelTranscriptionSession()
                statusMessage = "Recording too short. Speak a little longer before stopping."
                DebugLog.log("Recording rejected because duration was too short.", category: "app")
                return
            }

            if preparedRecording.rmsLevel < 0.001 {
                await dependencies.cancelTranscriptionSession()
                statusMessage = "No audio signal received. Check microphone and input level."
                DebugLog.log("Recording rejected because RMS was below threshold.", category: "app")
                return
            }

            statusMessage = "Finalizing \(AudioSettingsStore.transcriptionDisplayName)..."
            DebugLog.log("Finalizing transcript with the Whisper pipeline.", category: "app")

            let text = try await dependencies.finalizeTranscriptionSession(
                stopResult.trailingLiveSamples,
                preparedRecording.samples
            )
            finalizedTranscriptionSession = true
            let trimmedText = normalizeTranscript(text)

            DebugLog.log("Transcription completed. trimmedLength=\(trimmedText.count)", category: "app")

            guard !trimmedText.isEmpty else {
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
                    copyToClipboardOnFailure: autoCopyEnabled
                )
                scheduleInsertionWatchdog(transcript: trimmedText, autoCopyEnabled: autoCopyEnabled)
                let insertionOutcome: TextInsertionService.InsertionOutcome
                if liveInsertionActive && didCommitLiveTranscriptDelta {
                    insertionOutcome = dependencies.finalizeLiveInsertion(trimmedText, pendingInsertionTarget, insertionOptions)
                } else {
                    if liveInsertionActive {
                        DebugLog.log(
                            "Skipping live dictation finalization because no live transcript delta was committed. Falling back to the classic final insertion path.",
                            category: "insertion"
                        )
                    }
                    dismissOwnWindowsBeforeInsertion()
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
            if !finalizedTranscriptionSession {
                await dependencies.cancelTranscriptionSession()
            }
            statusMessage = error.localizedDescription
            DebugLog.log("Transcription flow failed: \(error)", category: "app")
        }
    }

    private func dismissOwnWindowsBeforeInsertion() {
        let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
        guard !visibleWindows.isEmpty else { return }

        let windowDescriptions = visibleWindows.map { window in
            let title = window.title.isEmpty ? "untitled" : window.title
            return "\(title){key=\(window.isKeyWindow)}"
        }.joined(separator: ", ")

        DebugLog.log(
            "Ordering out \(visibleWindows.count) spk window(s) before insertion: \(windowDescriptions)",
            category: "app"
        )

        visibleWindows.forEach { window in
            window.orderOut(nil)
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

    private func startLiveStreaming(insertIntoFocusedApp: Bool) {
        liveStreamingTask?.cancel()
        liveStreamingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.dependencies.startTranscriptionSession()
            } catch {
                DebugLog.log("Live streaming setup failed: \(error)", category: "transcription")
                self.degradeLiveStreamingToFinalOnly(insertIntoFocusedApp: insertIntoFocusedApp)
                return
            }

            while !Task.isCancelled && self.isRecording {
                let samples = await self.dependencies.takeLiveSamples()
                if !samples.isEmpty {
                    do {
                        try await self.dependencies.enqueueStreamingSamples(samples)
                    } catch {
                        DebugLog.log("Live streaming update failed: \(error)", category: "transcription")
                    }
                }

                do {
                    if let update = try await self.dependencies.takeStreamingUpdate() {
                        self.handleLiveStreamingUpdate(update, insertIntoFocusedApp: insertIntoFocusedApp)
                    }
                } catch {
                    DebugLog.log("Live streaming update failed: \(error)", category: "transcription")
                }

                do {
                    try await Task.sleep(for: Self.liveStreamingPollInterval)
                } catch {
                    break
                }
            }
        }
    }

    private func degradeLiveStreamingToFinalOnly(insertIntoFocusedApp: Bool) {
        dependencies.cancelLiveInsertion()
        committedLiveTranscript = ""
        previousLivePartialTranscript = ""
        liveTranscriptPreview = ""
        liveInsertionActive = false
        liveInsertionWindowDismissed = false
        didCommitLiveTranscriptDelta = false

        guard isRecording else { return }
        statusMessage = initialListeningStatusMessage(
            insertIntoFocusedApp: insertIntoFocusedApp,
            liveInsertionActive: false
        )
    }

    private func stopLiveStreaming() async {
        let task = liveStreamingTask
        liveStreamingTask = nil
        task?.cancel()
        await task?.value
    }

    private func handleLiveStreamingUpdate(
        _ update: StreamingTranscriptionUpdate,
        insertIntoFocusedApp: Bool
    ) {
        let normalizedPartial = normalizeTranscript(update.transcript)
        guard !normalizedPartial.isEmpty else { return }

        liveTranscriptPreview = normalizedPartial

        let commitCandidate = liveCommitCandidate(previous: previousLivePartialTranscript, current: normalizedPartial)
        previousLivePartialTranscript = normalizedPartial

        let delta = liveTranscriptDelta(from: committedLiveTranscript, to: commitCandidate)
        guard !delta.isEmpty else { return }

        if insertIntoFocusedApp && liveInsertionActive {
            if !liveInsertionWindowDismissed {
                dismissOwnWindowsBeforeInsertion()
                liveInsertionWindowDismissed = true
            }

            guard dependencies.appendLiveInsertionText(delta) else {
                DebugLog.log("Live insertion delta failed. deltaLength=\(delta.count)", category: "insertion")
                return
            }
        }

        committedLiveTranscript = normalizeTranscript(committedLiveTranscript + delta)
        didCommitLiveTranscriptDelta = true
        if insertIntoFocusedApp && liveInsertionActive {
            statusMessage = "Listening... typing live into the focused app."
        }
    }

    private func initialListeningStatusMessage(
        insertIntoFocusedApp: Bool,
        liveInsertionActive: Bool
    ) -> String {
        guard insertIntoFocusedApp else {
            return "Listening..."
        }

        guard liveInsertionActive else {
            return "Listening... this app is final-only, so spk will insert the transcript when you stop."
        }

        return "Listening... spk will type into the focused app as your words stabilize."
    }

    private static let liveStreamingPollInterval: Duration = .milliseconds(350)

    private func resetLiveTranscriptionState() {
        committedLiveTranscript = ""
        previousLivePartialTranscript = ""
        liveTranscriptPreview = ""
        liveInsertionActive = false
        liveInsertionWindowDismissed = false
        didCommitLiveTranscriptDelta = false
    }

    private func liveCommitCandidate(previous: String, current: String) -> String {
        stabilizedLiveCommitCandidate(previous: previous, current: current)
    }

    private func stabilizedLiveCommitCandidate(previous: String, current: String) -> String {
        let previousWords = normalizedWords(from: previous)
        let currentWords = normalizedWords(from: current)
        guard !previousWords.isEmpty, !currentWords.isEmpty else { return "" }

        let stableWordCount = zip(previousWords, currentWords)
            .prefix { $0 == $1 }
            .count
        guard stableWordCount > Self.liveTranscriptStabilityGuardWords else { return "" }

        return currentWords
            .prefix(stableWordCount - Self.liveTranscriptStabilityGuardWords)
            .joined(separator: " ")
    }

    private func liveTranscriptDelta(from committedTranscript: String, to candidateTranscript: String) -> String {
        let committedWords = normalizedWords(from: committedTranscript)
        let candidateWords = normalizedWords(from: candidateTranscript)

        guard candidateWords.count > committedWords.count else { return "" }
        guard Array(candidateWords.prefix(committedWords.count)) == committedWords else { return "" }

        let deltaWords = candidateWords.dropFirst(committedWords.count)
        let deltaText = deltaWords.joined(separator: " ")
        guard !deltaText.isEmpty else { return "" }

        return committedWords.isEmpty ? deltaText : " " + deltaText
    }

    private func normalizedWords(from text: String) -> [String] {
        normalizeTranscript(text)
            .split(separator: " ")
            .map(String.init)
    }

    private func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startInputLevelMonitoring() {
        inputLevelTask?.cancel()
        liveInputLevel = 0
        inputLevelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                let rawLevel = await self.dependencies.normalizedInputLevel()
                let smoothedLevel = max(Double(rawLevel), self.liveInputLevel * 0.82)
                self.liveInputLevel = min(max(smoothedLevel, 0), 1)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopInputLevelMonitoring() {
        inputLevelTask?.cancel()
        inputLevelTask = nil
        liveInputLevel = 0
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
            statusMessage = "Preparing \(AudioSettingsStore.transcriptionModelName). spk downloads it automatically if needed."
        case .requestingMicrophone:
            statusMessage = "Requesting microphone access so spk can finish startup."
        case .requestingAccessibility:
            statusMessage = "Approve Accessibility access in System Settings, then return here."
        case .ready:
            statusMessage = canUseGlobalTrigger
                ? "Press \(hotkeyHint) once to start dictating and watch text appear in the focused app as you speak. Press it again to finish."
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
            return "Press \(hotkeyHint) once to start dictating and watch text appear in the focused app as you speak. Press it again to finish."
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
