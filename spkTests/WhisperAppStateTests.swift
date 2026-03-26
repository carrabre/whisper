import Foundation
import XCTest
@testable import spk

@MainActor
final class WhisperAppStateTests: XCTestCase {
    func testCodeSigningStatusParsesStableTeamSignedOutput() {
        let status = Self.stableCodeSigningStatus()

        XCTAssertTrue(status.hasStableIdentity)
        XCTAssertEqual(status.teamIdentifier, "TEAMID12345")
        XCTAssertEqual(status.statusLabel, "Team TEAMID12345")
    }

    func testCodeSigningStatusParsesAdhocOutput() {
        let status = Self.adhocCodeSigningStatus()

        XCTAssertFalse(status.hasStableIdentity)
        XCTAssertEqual(status.signature, "adhoc")
        XCTAssertNil(status.teamIdentifier)
        XCTAssertEqual(status.statusLabel, "Ad hoc signed")
    }

    func testReleaseInstallValidatorRejectsAdhocSignature() {
        XCTAssertThrowsError(
            try ReleaseInstallValidator.validateCodesignOutput(
                Self.adhocCodeSigningStatusOutput(),
                expectedTeamIdentifier: "TEAMID12345"
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseInstallValidationError, .adHocSignature)
        }
    }

    func testReleaseInstallValidatorAcceptsStableSignature() throws {
        let status = try ReleaseInstallValidator.validateCodesignOutput(
            Self.stableCodeSigningStatusOutput(),
            expectedTeamIdentifier: "TEAMID12345"
        )

        XCTAssertEqual(status.teamIdentifier, "TEAMID12345")
        XCTAssertTrue(status.hasStableIdentity)
    }

    func testReleaseInstallValidatorRejectsUnexpectedTeamIdentifier() {
        XCTAssertThrowsError(
            try ReleaseInstallValidator.validateCodesignOutput(
                Self.stableCodeSigningStatusOutput(),
                expectedTeamIdentifier: "DIFFERENTTEAM"
            )
        ) { error in
            XCTAssertEqual(
                error as? ReleaseInstallValidationError,
                .unexpectedTeamIdentifier(expected: "DIFFERENTTEAM", actual: "TEAMID12345")
            )
        }
    }

    func testBootstrapWithGrantedPermissionsAndPreparedBackendReachesReady() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: {
                    events.append("prepare")
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium.bin"),
                        readyDisplayName: "ggml-medium.bin"
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertTrue(appState.modelReady)
        XCTAssertEqual(appState.startupSetupPhase, .ready)
        XCTAssertEqual(appState.startupProgressTitle, "Whisper readiness")
        XCTAssertEqual(events, ["prepare"])
    }

    func testBootstrapRequestsMicrophoneWhenStatusIsNotDetermined() async {
        let audioSettings = makeAudioSettings()
        var currentSnapshot = PermissionSnapshot(
            microphone: Self.notDeterminedPermission(),
            accessibility: Self.grantedPermission()
        )
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                permissionSnapshot: { currentSnapshot },
                requestMicrophonePermission: {
                    events.append("requestMicrophone")
                    currentSnapshot = PermissionSnapshot(
                        microphone: Self.grantedPermission(),
                        accessibility: Self.grantedPermission()
                    )
                    return true
                },
                prepareTranscription: {
                    events.append("prepare")
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium.bin"),
                        readyDisplayName: "ggml-medium.bin"
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertEqual(appState.startupSetupPhase, .ready)
        XCTAssertEqual(events, ["prepare", "requestMicrophone"])
    }

    func testBootstrapBackendFailureBlocksRecordingAndSurfacesMessage() async {
        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: {
                    throw WhisperBridge.WhisperBridgeError.invalidDownloadResponse
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        if case .failed(.backend(let message)) = appState.startupSetupPhase {
            XCTAssertEqual(message, WhisperBridge.WhisperBridgeError.invalidDownloadResponse.localizedDescription)
        } else {
            XCTFail("Expected backend failure, got \(appState.startupSetupPhase)")
        }
        XCTAssertFalse(appState.canRecord)
        XCTAssertEqual(appState.statusTitle, "Setup Failed")
    }

    func testToggleRecordingReturnsToReadyAfterSuccessfulInsertion() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []
        var insertedText: String?
        var copiedText: String?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                        trailingLiveSamples: []
                    )
                },
                prepareRecordingForTranscription: { _, sensitivity in
                    events.append("prepareRecording:\(String(format: "%.1f", sensitivity))")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                startTranscriptionSession: {
                    events.append("startStreaming")
                },
                finalizeTranscriptionSession: { _, fallbackSamples in
                    events.append("finalize")
                    XCTAssertEqual(fallbackSamples?.count, 8_000)
                    return "hello world"
                },
                insertText: { text, _, _ in
                    events.append("insertText")
                    insertedText = text
                    return .insertedAccessibility
                },
                copyTextToClipboard: { text in
                    events.append("copy")
                    copiedText = text
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        XCTAssertTrue(appState.isRecording)

        await appState.toggleRecordingFromButton()

        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertFalse(appState.isInserting)
        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(insertedText, "hello world")
        XCTAssertEqual(copiedText, "hello world")
        XCTAssertTrue(events.contains("startStreaming"))
        XCTAssertTrue(events.contains("finalize"))
        XCTAssertEqual(events.first, "cue:recordingWillStart")
        XCTAssertEqual(events.last, "cue:pipelineDidComplete")
    }

    func testStopCuePlaysWithoutCompletionCueWhenRecordingProducesNoFile() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        recordingURL: nil,
                        trailingLiveSamples: []
                    )
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.statusMessage, "The recording did not produce an audio file.")
        XCTAssertEqual(
            events,
            [
                "cue:recordingWillStart",
                "audioStart",
                "audioStop",
                "cue:recordingDidStop"
            ]
        )
    }

    func testToggleRecordingSkipsAudioCuesWhenDisabled() async {
        let audioSettings = makeAudioSettings()
        audioSettings.playAudioCues = false

        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                        trailingLiveSamples: []
                    )
                },
                prepareRecordingForTranscription: { _, _ in
                    PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                finalizeTranscriptionSession: { _, _ in
                    "hello world"
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(events, ["audioStart", "audioStop"])
    }

    func testLiveStreamingSetupFailureFallsBackToFinalOnlyRecording() async {
        struct LiveSetupFailure: LocalizedError {
            var errorDescription: String? { "stream setup failed" }
        }

        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                startTranscriptionSession: {
                    throw LiveSetupFailure()
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(
            appState.statusMessage,
            "Listening... this app is final-only, so spk will insert the transcript when you stop."
        )
    }

    func testListeningStatusMentionsStabilizedWordsWhenLiveInsertionIsActive() async {
        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                beginLiveInsertion: { _ in true }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()

        XCTAssertEqual(
            appState.statusMessage,
            "Listening... spk will type into the focused app as your words stabilize."
        )
    }

    func testLegacyTranscriptionDefaultsDoNotBlockStartup() async {
        let defaults = UserDefaults(suiteName: "WhisperAppStateTests.Legacy.\(UUID().uuidString)")!
        defaults.set("stale-mode", forKey: "transcription.mode")
        defaults.set("stale-profile", forKey: "ne" + "motron.latencyProfile")
        let audioSettings = AudioSettingsStore(userDefaults: defaults)

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertEqual(appState.startupSetupPhase, .ready)
        XCTAssertNil(defaults.object(forKey: "transcription.mode"))
        XCTAssertNil(defaults.object(forKey: "ne" + "motron.latencyProfile"))
    }

    private func makeDependencies(
        installDefaultHotkey: @escaping (@escaping () -> Void) -> HotkeyManager.ListenerStatus = { _ in .installed },
        resetDefaultHotkey: @escaping () -> HotkeyManager.ListenerStatus = { .inactive },
        permissionSnapshot: (() -> PermissionSnapshot)? = nil,
        codeSigningStatus: @escaping () -> CodeSigningStatus = {
            CodeSigningStatus(
                signature: "signed",
                authority: "Apple Development: Example Person",
                teamIdentifier: "TEAMID12345",
                hasStableIdentity: true
            )
        },
        requestMicrophonePermission: @escaping () async -> Bool = { true },
        promptForAccessibilityPermission: @escaping () -> Void = {},
        bundleVersionIdentifier: @escaping () -> String = { "1.0-1" },
        lastAccessibilityStartupPromptVersion: @escaping () -> String? = { nil },
        setLastAccessibilityStartupPromptVersion: @escaping (String?) -> Void = { _ in },
        audioStart: @escaping (String?) async throws -> Void = { _ in },
        audioStop: @escaping () async -> RecordingStopResult = {
            RecordingStopResult(
                recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                trailingLiveSamples: []
            )
        },
        takeLiveSamples: @escaping () async -> [Float] = { [] },
        prepareTranscription: @escaping () async throws -> TranscriptionPreparation = {
            TranscriptionPreparation(
                resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium.bin"),
                readyDisplayName: "ggml-medium.bin"
            )
        },
        prepareRecordingForTranscription: @escaping (URL, Double) async throws -> PreparedRecording = { _, _ in
            PreparedRecording(
                samples: Array(repeating: 0.2, count: 8_000),
                duration: 0.5,
                rmsLevel: 0.2
            )
        },
        startTranscriptionSession: @escaping () async throws -> Void = {},
        enqueueStreamingSamples: @escaping ([Float]) async throws -> Void = { _ in },
        takeStreamingUpdate: @escaping () async throws -> StreamingTranscriptionUpdate? = { nil },
        finalizeTranscriptionSession: @escaping ([Float], [Float]?) async throws -> String = { _, _ in "hello world" },
        cancelTranscriptionSession: @escaping () async -> Void = {},
        insertText: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome = { _, _, _ in .insertedAccessibility },
        beginLiveInsertion: @escaping (TextInsertionService.Target?) -> Bool = { _ in false },
        appendLiveInsertionText: @escaping (String) -> Bool = { _ in false },
        finalizeLiveInsertion: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome = { _, _, _ in .failedToInsert },
        cancelLiveInsertion: @escaping () -> Void = {},
        copyTextToClipboard: @escaping (String) -> Void = { _ in },
        playAudioCue: @escaping (AudioCue) -> Void = { _ in }
    ) -> WhisperAppDependencies {
        let defaultPermissionSnapshot = PermissionSnapshot(
            microphone: Self.grantedPermission(),
            accessibility: Self.grantedPermission()
        )
        let resolvedPermissionSnapshot = permissionSnapshot ?? { defaultPermissionSnapshot }

        return WhisperAppDependencies(
            installDefaultHotkey: installDefaultHotkey,
            resetDefaultHotkey: resetDefaultHotkey,
            permissionSnapshot: resolvedPermissionSnapshot,
            codeSigningStatus: codeSigningStatus,
            requestMicrophonePermission: requestMicrophonePermission,
            promptForAccessibilityPermission: promptForAccessibilityPermission,
            openMicrophoneSettings: {},
            openAccessibilitySettings: {},
            bundleVersionIdentifier: bundleVersionIdentifier,
            lastAccessibilityStartupPromptVersion: lastAccessibilityStartupPromptVersion,
            setLastAccessibilityStartupPromptVersion: setLastAccessibilityStartupPromptVersion,
            audioStart: audioStart,
            audioStop: audioStop,
            takeLiveSamples: takeLiveSamples,
            normalizedInputLevel: { 0.6 },
            prepareTranscription: prepareTranscription,
            modelDirectoryURL: { URL(fileURLWithPath: "/tmp") },
            startTranscriptionSession: startTranscriptionSession,
            enqueueStreamingSamples: enqueueStreamingSamples,
            takeStreamingUpdate: takeStreamingUpdate,
            finalizeTranscriptionSession: finalizeTranscriptionSession,
            cancelTranscriptionSession: cancelTranscriptionSession,
            prepareRecordingForTranscription: prepareRecordingForTranscription,
            captureInsertionTarget: {
                TextInsertionService.Target(
                    applicationPID: 321,
                    applicationName: "Notes",
                    bundleIdentifier: "com.apple.Notes"
                )
            },
            insertText: insertText,
            beginLiveInsertion: beginLiveInsertion,
            appendLiveInsertionText: appendLiveInsertionText,
            finalizeLiveInsertion: finalizeLiveInsertion,
            cancelLiveInsertion: cancelLiveInsertion,
            copyTextToClipboard: copyTextToClipboard,
            playAudioCue: playAudioCue
        )
    }

    private func makeAudioSettings() -> AudioSettingsStore {
        let defaults = UserDefaults(suiteName: "WhisperAppStateTests.\(UUID().uuidString)")!
        return AudioSettingsStore(userDefaults: defaults)
    }

    private func settleQueuedTasks() async {
        for _ in 0..<8 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(350))
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private static func grantedPermission() -> PermissionState {
        PermissionState(
            isGranted: true,
            description: "Granted",
            explanation: "",
            canRequestDirectly: false,
            needsSystemSettings: false
        )
    }

    private static func notDeterminedPermission() -> PermissionState {
        PermissionState(
            isGranted: false,
            description: "Not requested",
            explanation: "",
            canRequestDirectly: true,
            needsSystemSettings: false
        )
    }

    private static func stableCodeSigningStatus() -> CodeSigningStatus {
        CodeSigningStatus.fromCodesignOutput(stableCodeSigningStatusOutput())
    }

    private static func adhocCodeSigningStatus() -> CodeSigningStatus {
        CodeSigningStatus.fromCodesignOutput(adhocCodeSigningStatusOutput())
    }

    private static func stableCodeSigningStatusOutput() -> String {
        """
        Authority=Apple Development: Example Person
        TeamIdentifier=TEAMID12345
        """
    }

    private static func adhocCodeSigningStatusOutput() -> String {
        """
        CodeDirectory v=20400 size=9799 flags=0x2(adhoc) hashes=296+7 location=embedded
        Signature=adhoc
        TeamIdentifier=not set
        """
    }
}
