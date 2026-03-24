import AppKit
import Foundation
import SwiftUI

struct WhisperAppDependencies {
    let installDefaultHotkey: (@escaping () -> Void) -> Void
    let permissionSnapshot: () -> PermissionSnapshot
    let requestMicrophonePermission: () async -> Bool
    let promptForAccessibilityPermission: () -> Void
    let openMicrophoneSettings: () -> Void
    let openAccessibilitySettings: () -> Void
    let audioStart: (String?) async throws -> Void
    let audioStop: () async -> URL?
    let normalizedInputLevel: () async -> Float
    let prepareModel: () async throws -> URL
    let modelDirectoryURL: () async throws -> URL
    let transcribe: ([Float]) async throws -> String
    let loadSamples: (URL) throws -> [Float]
    let recordingDuration: ([Float]) -> Double
    let applyInputSensitivity: (Double, [Float]) -> [Float]
    let rmsLevel: ([Float]) -> Float
    let captureInsertionTarget: () -> TextInsertionService.Target?
    let insertText: (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome
    let copyTextToClipboard: (String) -> Void

    static func live(
        permissionsManager: PermissionsManager = PermissionsManager(),
        audioRecorder: AudioRecorder = AudioRecorder(),
        whisperBridge: WhisperBridge = WhisperBridge(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        hotkeyManager: HotkeyManager = HotkeyManager()
    ) -> Self {
        WhisperAppDependencies(
            installDefaultHotkey: { onTrigger in
                hotkeyManager.installDefault(onTrigger: onTrigger)
            },
            permissionSnapshot: {
                permissionsManager.snapshot()
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
            audioStart: { preferredInputDeviceID in
                try await audioRecorder.start(preferredInputDeviceID: preferredInputDeviceID)
            },
            audioStop: {
                await audioRecorder.stop()
            },
            normalizedInputLevel: {
                await audioRecorder.normalizedInputLevel()
            },
            prepareModel: {
                try await whisperBridge.prepareModel()
            },
            modelDirectoryURL: {
                try await whisperBridge.modelDirectoryURL()
            },
            transcribe: { samples in
                try await whisperBridge.transcribe(samples: samples)
            },
            loadSamples: { url in
                try AudioRecorder.loadSamples(from: url)
            },
            recordingDuration: { samples in
                AudioRecorder.recordingDuration(samples: samples)
            },
            applyInputSensitivity: { sensitivity, samples in
                AudioRecorder.applyInputSensitivity(sensitivity, to: samples)
            },
            rmsLevel: { samples in
                AudioRecorder.rmsLevel(samples: samples)
            },
            captureInsertionTarget: {
                textInsertionService.captureInsertionTarget()
            },
            insertText: { text, target, options in
                textInsertionService.insert(text, target: target, options: options)
            },
            copyTextToClipboard: { text in
                textInsertionService.copyToClipboard(text)
            }
        )
    }
}

@MainActor
final class WhisperAppState: ObservableObject {
    private static let insertionWatchdogDelay: TimeInterval = 3

    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isInserting = false
    @Published private(set) var modelReady = false
    @Published private(set) var statusMessage = "Starting up..."
    @Published private(set) var modelMessage = "Checking for whisper-medium..."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var permissions = PermissionSnapshot.current()
    @Published private(set) var liveInputLevel: Double = 0

    let hotkeyHint = HotkeyManager.defaultShortcutDisplay
    let audioSettings: AudioSettingsStore

    private let dependencies: WhisperAppDependencies
    private var shouldInsertAfterRecording = true
    private var pendingInsertionTarget: TextInsertionService.Target?
    private var inputLevelTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var insertionWatchdogToken: UUID?

    init(
        audioSettings: AudioSettingsStore,
        dependencies: WhisperAppDependencies = .live(),
        bootstrapsOnInit: Bool = true
    ) {
        self.audioSettings = audioSettings
        self.dependencies = dependencies
        self.permissions = dependencies.permissionSnapshot()
        DebugLog.log(
            "WhisperAppState initialized. selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity)) autoCopy=\(audioSettings.automaticallyCopyTranscripts)",
            category: "app"
        )

        dependencies.installDefaultHotkey { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleHotkeyToggle()
            }
        }

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
        if !permissions.microphone.isGranted || !permissions.accessibility.isGranted {
            return "Permissions Needed"
        }
        if !modelReady {
            return "Preparing Model"
        }
        return "Ready"
    }

    var canRecord: Bool {
        !isPreparingModel && !isTranscribing && !isInserting
    }

    func bootstrap() async {
        DebugLog.log("Bootstrapping app state.", category: "app")
        refreshPermissions()
        await prepareModelIfNeeded()
        updateStatusMessage()
    }

    func refreshPermissions() {
        permissions = dependencies.permissionSnapshot()
        DebugLog.log(
            "Permissions refreshed. microphone=\(permissions.microphone.description) accessibility=\(permissions.accessibility.description)",
            category: "permissions"
        )
        updateStatusMessage()
    }

    func requestMicrophonePermission() async {
        _ = await dependencies.requestMicrophonePermission()
        refreshPermissions()
        if permissions.microphone.isGranted {
            statusMessage = "Microphone access granted."
        } else {
            statusMessage = "spk needs microphone access to record dictation."
        }
    }

    func requestAccessibilityPermission() {
        dependencies.promptForAccessibilityPermission()
        statusMessage = "Approve Accessibility access in System Settings, then return here."
        DebugLog.log("Accessibility permission prompt requested from UI.", category: "permissions")
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        dependencies.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        dependencies.openAccessibilitySettings()
    }

    func prepareModelIfNeeded() async {
        guard !isPreparingModel else { return }

        isPreparingModel = true
        statusMessage = "Preparing whisper-medium. spk downloads it automatically if needed."
        modelMessage = "Preparing whisper-medium..."
        DebugLog.log("Preparing model.", category: "model")
        do {
            let modelURL = try await dependencies.prepareModel()
            modelReady = true
            modelMessage = "Ready: \(modelURL.lastPathComponent)"
            DebugLog.log("Model ready at \(modelURL.path)", category: "model")
        } catch {
            modelReady = false
            modelMessage = "Model setup failed"
            statusMessage = error.localizedDescription
            DebugLog.log("Model preparation failed: \(error)", category: "model")
        }
        isPreparingModel = false
    }

    func retryModelSetup() async {
        await prepareModelIfNeeded()
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
        } else {
            await startRecording(trigger: "hotkey", insertIntoFocusedApp: true)
        }
    }

    private func startRecording(trigger: String, insertIntoFocusedApp: Bool) async {
        guard !isPreparingModel, !isTranscribing, !isInserting else { return }

        if insertIntoFocusedApp {
            pendingInsertionTarget = dependencies.captureInsertionTarget()
        } else {
            pendingInsertionTarget = nil
        }

        DebugLog.log(
            "Start recording requested. trigger=\(trigger) insert=\(insertIntoFocusedApp) selectedInput=\(audioSettings.selectedInputDeviceID ?? "system-default") sensitivity=\(String(format: "%.2f", audioSettings.inputSensitivity))",
            category: "app"
        )

        refreshPermissions()
        if !permissions.microphone.isGranted && permissions.microphone.canRequestDirectly {
            _ = await dependencies.requestMicrophonePermission()
            refreshPermissions()
        }

        guard permissions.microphone.isGranted else {
            statusMessage = "Microphone permission is required before dictation can start."
            DebugLog.log("Start recording blocked: microphone permission missing.", category: "app")
            return
        }

        if insertIntoFocusedApp && !permissions.accessibility.isGranted {
            dependencies.promptForAccessibilityPermission()
            statusMessage = "Accessibility permission is required to type into other apps."
            DebugLog.log("Start recording blocked: accessibility permission missing.", category: "app")
            return
        }

        if !modelReady {
            statusMessage = "Whisper medium is still getting ready."
            DebugLog.log("Start recording paused because model is not ready yet.", category: "app")
            await prepareModelIfNeeded()
            guard modelReady else { return }
        }

        do {
            try await dependencies.audioStart(audioSettings.selectedInputDeviceID)
            shouldInsertAfterRecording = insertIntoFocusedApp
            isRecording = true
            statusMessage = "Listening..."
            startInputLevelMonitoring()
            DebugLog.log("Recording started.", category: "app")
        } catch {
            statusMessage = error.localizedDescription
            liveInputLevel = 0
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
            DebugLog.log(
                "Reset transient recording state. recording=\(isRecording) transcribing=\(isTranscribing) inserting=\(isInserting)",
                category: "app"
            )
        }

        let recordingURL = await dependencies.audioStop()
        isRecording = false
        stopInputLevelMonitoring()

        guard let recordingURL else {
            statusMessage = "The recording did not produce an audio file."
            DebugLog.log("Recording produced no file.", category: "app")
            return
        }

        DebugLog.log("Recording stopped. file=\(recordingURL.path)", category: "app")

        do {
            let samples = try dependencies.loadSamples(recordingURL)
            let duration = dependencies.recordingDuration(samples)

            DebugLog.log(
                "Loaded \(samples.count) samples. duration=\(String(format: "%.2f", duration))s",
                category: "app"
            )

            if duration < 0.3 {
                statusMessage = "Recording too short. Hold the shortcut or button longer."
                DebugLog.log("Recording rejected because duration was too short.", category: "app")
                return
            }

            let adjustedSamples = dependencies.applyInputSensitivity(
                audioSettings.inputSensitivity,
                samples
            )
            let rms = dependencies.rmsLevel(adjustedSamples)

            DebugLog.log("Adjusted RMS level: \(String(format: "%.4f", rms))", category: "app")

            if rms < 0.001 {
                statusMessage = "No audio signal received. Check microphone and input level."
                DebugLog.log("Recording rejected because RMS was below threshold.", category: "app")
                return
            }

            isTranscribing = true
            statusMessage = "Transcribing with whisper-medium..."
            DebugLog.log("Handing audio to whisper for transcription.", category: "app")

            let text = try await dependencies.transcribe(adjustedSamples)
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            DebugLog.log("Transcription completed. trimmedLength=\(trimmedText.count)", category: "app")

            guard !trimmedText.isEmpty else {
                statusMessage = "No speech was detected in the recording."
                DebugLog.log(
                    "Whisper returned an empty transcript for non-silent audio. Treating this as a transcription/decode issue.",
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
                dismissOwnWindowsBeforeInsertion()
                let insertionOptions = TextInsertionService.InsertionOptions(
                    restoreClipboardAfterPaste: !autoCopyEnabled,
                    copyToClipboardOnFailure: autoCopyEnabled
                )
                scheduleInsertionWatchdog(transcript: trimmedText, autoCopyEnabled: autoCopyEnabled)
                let insertionOutcome = dependencies.insertText(trimmedText, pendingInsertionTarget, insertionOptions)
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
        } catch {
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
                if latestPermissions.microphone.isGranted != self.permissions.microphone.isGranted ||
                    latestPermissions.accessibility.isGranted != self.permissions.accessibility.isGranted ||
                    latestPermissions.microphone.description != self.permissions.microphone.description ||
                    latestPermissions.accessibility.description != self.permissions.accessibility.description {
                    DebugLog.log(
                        "Permission state changed. microphone=\(latestPermissions.microphone.description) accessibility=\(latestPermissions.accessibility.description)",
                        category: "permissions"
                    )
                    self.permissions = latestPermissions
                    self.updateStatusMessage()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusMessage() {
        if isRecording || isTranscribing || isInserting {
            return
        }

        if !permissions.microphone.isGranted || !permissions.accessibility.isGranted {
            statusMessage = "Finish granting permissions, then return to spk."
        } else if modelReady {
            statusMessage = "Press \(hotkeyHint) to start dictating, then press it again to transcribe into the focused app."
        } else {
            statusMessage = "spk is preparing whisper-medium and will download it automatically if it is missing."
        }
    }
}
