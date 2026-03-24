import Foundation
import XCTest
@testable import spk

@MainActor
final class WhisperAppStateTests: XCTestCase {
    func testToggleRecordingReturnsToReadyAfterSuccessfulInsertion() async {
        let audioSettings = AudioSettingsStore(userDefaults: UserDefaults(suiteName: "WhisperAppStateTests.\(UUID().uuidString)")!)
        var insertedText: String?
        var receivedInsertionOptions: TextInsertionService.InsertionOptions?
        var copiedText: String?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                transcribe: { _ in "hello world" },
                insertText: { text, _, options in
                    insertedText = text
                    receivedInsertionOptions = options
                    return .insertedAccessibility
                },
                copyTextToClipboard: { copiedText = $0 }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        XCTAssertTrue(appState.isRecording)

        await appState.toggleRecordingFromButton()

        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertFalse(appState.isInserting)
        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(insertedText, "hello world")
        XCTAssertEqual(receivedInsertionOptions?.restoreClipboardAfterPaste, false)
        XCTAssertEqual(receivedInsertionOptions?.copyToClipboardOnFailure, true)
        XCTAssertEqual(copiedText, "hello world")
    }

    private func makeDependencies(
        permissionSnapshot: @escaping () -> PermissionSnapshot = {
            PermissionSnapshot(
                microphone: PermissionState(
                    isGranted: true,
                    description: "Granted",
                    explanation: "",
                    canRequestDirectly: false,
                    needsSystemSettings: false
                ),
                accessibility: PermissionState(
                    isGranted: true,
                    description: "Granted",
                    explanation: "",
                    canRequestDirectly: false,
                    needsSystemSettings: false
                )
            )
        },
        prepareModel: @escaping () async throws -> URL = {
            URL(fileURLWithPath: "/tmp/fake-model.bin")
        },
        transcribe: @escaping ([Float]) async throws -> String,
        insertText: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome,
        copyTextToClipboard: @escaping (String) -> Void
    ) -> WhisperAppDependencies {
        WhisperAppDependencies(
            installDefaultHotkey: { _ in },
            permissionSnapshot: permissionSnapshot,
            requestMicrophonePermission: { true },
            promptForAccessibilityPermission: {},
            openMicrophoneSettings: {},
            openAccessibilitySettings: {},
            audioStart: { _ in },
            audioStop: { URL(fileURLWithPath: "/tmp/fake-recording.wav") },
            normalizedInputLevel: { 0.6 },
            prepareModel: prepareModel,
            modelDirectoryURL: { URL(fileURLWithPath: "/tmp") },
            transcribe: transcribe,
            loadSamples: { _ in Array(repeating: 0.2, count: 8_000) },
            recordingDuration: { _ in 0.5 },
            applyInputSensitivity: { _, samples in samples },
            rmsLevel: { _ in 0.2 },
            captureInsertionTarget: {
                TextInsertionService.Target(
                    applicationPID: 321,
                    applicationName: "Notes",
                    bundleIdentifier: "com.apple.Notes"
                )
            },
            insertText: insertText,
            copyTextToClipboard: copyTextToClipboard
        )
    }
}
