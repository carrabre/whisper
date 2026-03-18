import AppKit
import Foundation
import SwiftUI

@MainActor
final class WhisperAppState: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var modelReady = false
    @Published private(set) var statusMessage = "Starting up..."
    @Published private(set) var modelMessage = "Checking for whisper-medium..."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var permissions = PermissionSnapshot.current()
    @Published private(set) var recordingIndicatorVisible = true

    let hotkeyHint = HotkeyManager.defaultShortcutDisplay

    let audioSettings: AudioSettingsStore

    private let permissionsManager = PermissionsManager()
    private let audioRecorder = AudioRecorder()
    private let whisperBridge = WhisperBridge()
    private let textInsertionService = TextInsertionService()
    private let hotkeyManager = HotkeyManager()
    private var shouldInsertAfterRecording = true
    private var recordingBlinkTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?

    init(audioSettings: AudioSettingsStore) {
        self.audioSettings = audioSettings

        hotkeyManager.installDefault(
            onKeyDown: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleHotkeyDown()
                }
            },
            onKeyUp: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleHotkeyUp()
                }
            }
        )

        startPermissionRefreshLoop()

        Task {
            await bootstrap()
        }
    }

    deinit {
        permissionRefreshTask?.cancel()
        recordingBlinkTask?.cancel()
    }

    var menuBarSymbolName: String {
        if isRecording {
            return recordingIndicatorVisible ? "record.circle.fill" : "record.circle"
        }
        if isTranscribing {
            return "waveform.and.magnifyingglass"
        }
        return "waveform"
    }

    var menuBarSymbolColor: Color {
        if isRecording {
            return .red
        }
        if isTranscribing {
            return .orange
        }
        return .primary
    }

    var statusTitle: String {
        if isRecording {
            return "Recording"
        }
        if isTranscribing {
            return "Transcribing"
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
        !isPreparingModel && !isTranscribing
    }

    func bootstrap() async {
        refreshPermissions()
        await prepareModelIfNeeded()
        updateStatusMessage()
    }

    func refreshPermissions() {
        permissions = permissionsManager.snapshot()
        updateStatusMessage()
    }

    func requestMicrophonePermission() async {
        _ = await permissionsManager.requestMicrophonePermission()
        refreshPermissions()
        if permissions.microphone.isGranted {
            statusMessage = "Microphone access granted."
        } else {
            statusMessage = "spk needs microphone access to record dictation."
        }
    }

    func requestAccessibilityPermission() {
        permissionsManager.promptForAccessibilityPermission()
        statusMessage = "Approve Accessibility access in System Settings, then return here."
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        permissionsManager.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }

    func prepareModelIfNeeded() async {
        guard !isPreparingModel else { return }

        isPreparingModel = true
        modelMessage = "Preparing whisper-medium..."
        do {
            let modelURL = try await whisperBridge.prepareModel()
            modelReady = true
            modelMessage = "Ready: \(modelURL.lastPathComponent)"
        } catch {
            modelReady = false
            modelMessage = "Model setup failed"
            statusMessage = error.localizedDescription
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
                let folder = try await whisperBridge.modelDirectoryURL()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func handleHotkeyDown() async {
        guard !isRecording else { return }
        await startRecording(trigger: "hotkey", insertIntoFocusedApp: true)
    }

    private func handleHotkeyUp() async {
        guard isRecording else { return }
        await finishRecording(insertIntoFocusedApp: true)
    }

    private func startRecording(trigger: String, insertIntoFocusedApp: Bool) async {
        guard !isPreparingModel, !isTranscribing else { return }

        refreshPermissions()
        if !permissions.microphone.isGranted && permissions.microphone.canRequestDirectly {
            _ = await permissionsManager.requestMicrophonePermission()
            refreshPermissions()
        }

        guard permissions.microphone.isGranted else {
            statusMessage = "Microphone permission is required before dictation can start."
            return
        }

        if insertIntoFocusedApp && !permissions.accessibility.isGranted {
            permissionsManager.promptForAccessibilityPermission()
            statusMessage = "Accessibility permission is required to type into other apps."
            return
        }

        if !modelReady {
            statusMessage = "Whisper medium is still getting ready."
            await prepareModelIfNeeded()
            guard modelReady else { return }
        }

        do {
            try await audioRecorder.start(preferredInputDeviceID: audioSettings.selectedInputDeviceID)
            shouldInsertAfterRecording = insertIntoFocusedApp
            isRecording = true
            statusMessage = "Listening..."
            startRecordingIndicatorBlink()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func finishRecording(insertIntoFocusedApp: Bool) async {
        guard isRecording else { return }

        let recordingURL = await audioRecorder.stop()
        isRecording = false
        stopRecordingIndicatorBlink()

        guard let recordingURL else {
            statusMessage = "The recording did not produce an audio file."
            return
        }

        do {
            isTranscribing = true
            statusMessage = "Transcribing with whisper-medium..."

            let samples = try AudioRecorder.loadSamples(from: recordingURL)
            let adjustedSamples = AudioRecorder.applyInputSensitivity(
                audioSettings.inputSensitivity,
                to: samples
            )
            let text = try await whisperBridge.transcribe(samples: adjustedSamples)
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedText.isEmpty else {
                statusMessage = "No speech was detected."
                isTranscribing = false
                return
            }

            lastTranscript = trimmedText

            if insertIntoFocusedApp {
                try textInsertionService.insert(trimmedText)
                statusMessage = "Inserted transcription into the focused app."
            } else {
                statusMessage = "Transcription ready."
            }
        } catch {
            statusMessage = error.localizedDescription
        }

        isTranscribing = false
    }

    private func startRecordingIndicatorBlink() {
        recordingBlinkTask?.cancel()
        recordingIndicatorVisible = true
        recordingBlinkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled || !self.isRecording { break }
                self.recordingIndicatorVisible.toggle()
            }
        }
    }

    private func stopRecordingIndicatorBlink() {
        recordingBlinkTask?.cancel()
        recordingBlinkTask = nil
        recordingIndicatorVisible = true
    }

    private func startPermissionRefreshLoop() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let latestPermissions = self.permissionsManager.snapshot()
                if latestPermissions.microphone.isGranted != self.permissions.microphone.isGranted ||
                    latestPermissions.accessibility.isGranted != self.permissions.accessibility.isGranted ||
                    latestPermissions.microphone.description != self.permissions.microphone.description ||
                    latestPermissions.accessibility.description != self.permissions.accessibility.description {
                    self.permissions = latestPermissions
                    self.updateStatusMessage()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusMessage() {
        if isRecording || isTranscribing {
            return
        }

        if !permissions.microphone.isGranted || !permissions.accessibility.isGranted {
            statusMessage = "Finish granting permissions, then return to spk."
        } else if modelReady {
            statusMessage = "Hold \(hotkeyHint) to dictate into the focused app."
        } else {
            statusMessage = "Grant permissions and finish the model download to start dictating."
        }
    }
}
