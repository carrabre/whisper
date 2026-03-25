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

    func testToggleRecordingReturnsToReadyAfterSuccessfulInsertion() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []
        var insertedText: String?
        var receivedInsertionOptions: TextInsertionService.InsertionOptions?
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
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello world"
                },
                insertText: { text, _, options in
                    events.append("insertText")
                    insertedText = text
                    receivedInsertionOptions = options
                    return .insertedAccessibility
                },
                copyTextToClipboard: {
                    events.append("copy")
                    copiedText = $0
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
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
        XCTAssertEqual(
            events,
            [
                "cue:recordingWillStart",
                "audioStart",
                "audioStop",
                "cue:recordingDidStop",
                "prepareRecording:1.0",
                "finalize:englishRealtimeNemotron",
                "insertText",
                "copy",
                "cue:pipelineDidComplete"
            ]
        )
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
                finalizeTranscriptionSession: { _, _, _ in
                    events.append("finalize")
                    return "hello world"
                },
                insertText: { _, _, _ in
                    events.append("insertText")
                    return .insertedAccessibility
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
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
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello world"
                },
                insertText: { _, _, _ in
                    events.append("insertText")
                    return .insertedAccessibility
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await appState.toggleRecordingFromButton()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "audioStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "insertText",
                "copy"
            ]
        )
    }

    func testStatusMessageUsesSupportedShortcutCopyWhenHotkeyIsInstalled() async {
        let audioSettings = makeAudioSettings()

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.prepareModelIfNeeded()
        appState.refreshPermissions()

        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertTrue(appState.canUseGlobalTrigger)
        XCTAssertEqual(appState.hotkeyHint, "Cmd+Shift+Space")
        XCTAssertEqual(appState.hotkeySessionStateLabel, "Standing by")
        XCTAssertEqual(
            appState.statusMessage,
            "Press Cmd+Shift+Space once to start dictating and watch text appear in the focused app as you speak. Press it again to finish."
        )
    }

    func testAdhocSigningStatusPreventsReadyCopy() async {
        let audioSettings = makeAudioSettings()

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                codeSigningStatus: { Self.adhocCodeSigningStatus() },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.prepareModelIfNeeded()
        appState.refreshPermissions()

        XCTAssertFalse(appState.hasStableSigningIdentity)
        XCTAssertEqual(appState.statusTitle, "Signed Build Needed")
        XCTAssertEqual(
            appState.statusMessage,
            "This copy of spk is ad hoc signed. Reinstall a team-signed build to keep Accessibility stable across rebuilds."
        )
    }

    func testBootstrapWithGrantedPermissionsAndPreparedBackendReachesReady() async {
        let audioSettings = makeAudioSettings()

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        if case .ready = appState.startupSetupPhase {
        } else {
            XCTFail("Expected startup setup to reach ready.")
        }
        XCTAssertTrue(appState.modelReady)
        XCTAssertTrue(appState.canRecord)
        XCTAssertEqual(appState.statusTitle, "Ready")
    }

    func testBootstrapRequestsMicrophoneWhenStatusIsNotDetermined() async {
        let audioSettings = makeAudioSettings()
        var microphoneGranted = false
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                permissionSnapshot: {
                    PermissionSnapshot(
                        microphone: microphoneGranted ? Self.grantedPermission() : Self.notDeterminedPermission(),
                        accessibility: Self.grantedPermission()
                    )
                },
                requestMicrophonePermission: {
                    events.append("requestMicrophone")
                    microphoneGranted = true
                    return true
                },
                prepareTranscription: { mode in
                    events.append("prepare:\(mode.rawValue)")
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/\(mode.rawValue).bin"),
                        readyDisplayName: mode.modelSetupName
                    )
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        if case .ready = appState.startupSetupPhase {
        } else {
            XCTFail("Expected startup setup to reach ready after requesting microphone access.")
        }
        XCTAssertEqual(events, ["prepare:englishRealtimeNemotron", "requestMicrophone"])
        XCTAssertTrue(appState.permissions.microphone.isGranted)
    }

    func testBootstrapPromptsAccessibilityOnlyOncePerBuildVersion() async {
        let audioSettings = makeAudioSettings()
        var accessibilityGranted = false
        var promptCount = 0
        var lastPromptVersion: String?
        let buildVersionIdentifier = "1.2-3"

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                permissionSnapshot: {
                    PermissionSnapshot(
                        microphone: Self.grantedPermission(),
                        accessibility: accessibilityGranted ? Self.grantedPermission() : Self.requiredPermission()
                    )
                },
                promptForAccessibilityPermission: {
                    promptCount += 1
                },
                bundleVersionIdentifier: {
                    buildVersionIdentifier
                },
                lastAccessibilityStartupPromptVersion: {
                    lastPromptVersion
                },
                setLastAccessibilityStartupPromptVersion: { version in
                    lastPromptVersion = version
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(lastPromptVersion, buildVersionIdentifier)
        if case .failed(.accessibilityPermission) = appState.startupSetupPhase {
        } else {
            XCTFail("Expected accessibility setup to stay blocked until permission is granted.")
        }

        await appState.bootstrap()
        XCTAssertEqual(promptCount, 1)

        accessibilityGranted = true
        appState.refreshPermissions()

        if case .ready = appState.startupSetupPhase {
        } else {
            XCTFail("Expected startup setup to become ready after accessibility is granted.")
        }
        XCTAssertNil(lastPromptVersion)
    }

    func testBootstrapBackendFailureBlocksRecordingAndSurfacesURL() async {
        let audioSettings = makeAudioSettings()
        let failingURL = "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/main/nemotron-speech-streaming-en-0.6b.nemo"

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: { _ in
                    throw NemotronBridge.NemotronBridgeError.invalidDownloadResponse(
                        statusCode: 404,
                        downloadURL: failingURL
                    )
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertEqual(appState.selectedTranscriptionMode, .englishRealtimeNemotron)
        XCTAssertFalse(appState.canRecord)
        XCTAssertFalse(appState.modelReady)
        XCTAssertEqual(appState.statusTitle, "Setup Failed")
        XCTAssertTrue(appState.statusMessage.contains("HTTP 404"))
        XCTAssertTrue(appState.statusMessage.contains(failingURL))
        if case .failed(.backend(let message)) = appState.startupSetupPhase {
            XCTAssertTrue(message.contains(failingURL))
        } else {
            XCTFail("Expected backend setup failure.")
        }
    }

    func testLiveStreamingAppendsStableDeltaBeforeFinalization() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []
        var liveSamples = [
            Array(repeating: Float(0.2), count: 20_000),
            Array(repeating: Float(0.2), count: 20_000)
        ]
        var partials = [
            "hello there general",
            "hello there general kenobi"
        ]
        var appendedLiveText: [String] = []
        var finalizedText: String?

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
                takeLiveSamples: {
                    liveSamples.isEmpty ? [] : liveSamples.removeFirst()
                },
                prepareRecordingForTranscription: { _, _ in
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                startTranscriptionSession: { mode in
                    events.append("startStreaming:\(mode.rawValue)")
                },
                appendStreamingSamples: { _ in
                    guard !partials.isEmpty else { return nil }
                    events.append("appendStreaming")
                    return StreamingTranscriptionUpdate(
                        transcript: partials.removeFirst(),
                        decodeMilliseconds: 12
                    )
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello there general kenobi"
                },
                insertText: { _, _, _ in
                    XCTFail("Final insertText should not run when live insertion is active")
                    return .failedToInsert
                },
                beginLiveInsertion: { _ in
                    events.append("beginLiveInsertion")
                    return true
                },
                appendLiveInsertionText: { text in
                    appendedLiveText.append(text)
                    return true
                },
                finalizeLiveInsertion: { text, _, _ in
                    finalizedText = text
                    events.append("finalizeLiveInsertion")
                    return .insertedTyping
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        try? await Task.sleep(for: .milliseconds(850))
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "hello there general kenobi")
        XCTAssertEqual(appendedLiveText, ["hello"])
        XCTAssertEqual(finalizedText, "hello there general kenobi")
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "beginLiveInsertion",
                "startStreaming:englishRealtimeNemotron",
                "appendStreaming",
                "appendStreaming",
                "audioStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "finalizeLiveInsertion",
                "copy"
            ]
        )
    }

    func testLiveStreamingWithoutCommittedDeltaFallsBackToClassicInsertion() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []
        var liveSamples = [
            Array(repeating: Float(0.2), count: 20_000)
        ]
        var insertedText: String?

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
                takeLiveSamples: {
                    liveSamples.isEmpty ? [] : liveSamples.removeFirst()
                },
                prepareRecordingForTranscription: { _, _ in
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                startTranscriptionSession: { mode in
                    events.append("startStreaming:\(mode.rawValue)")
                },
                appendStreamingSamples: { _ in
                    events.append("appendStreaming")
                    return StreamingTranscriptionUpdate(
                        transcript: "hello",
                        decodeMilliseconds: 12
                    )
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello world"
                },
                insertText: { text, _, _ in
                    insertedText = text
                    events.append("insertText")
                    return .insertedAccessibility
                },
                beginLiveInsertion: { _ in
                    events.append("beginLiveInsertion")
                    return true
                },
                appendLiveInsertionText: { _ in
                    XCTFail("No live delta should be inserted when nothing stabilizes")
                    return false
                },
                finalizeLiveInsertion: { _, _, _ in
                    XCTFail("Final live insertion should not run without a committed live delta")
                    return .failedToInsert
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        try? await Task.sleep(for: .milliseconds(450))
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(insertedText, "hello world")
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "beginLiveInsertion",
                "startStreaming:englishRealtimeNemotron",
                "appendStreaming",
                "audioStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "insertText",
                "copy"
            ]
        )
    }

    func testLiveStreamingSetupFailureSurfacesNemotronError() async {
        struct StreamingSetupFailure: Error {}

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
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                        trailingLiveSamples: []
                    )
                },
                prepareRecordingForTranscription: { _, _ in
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                startTranscriptionSession: { mode in
                    events.append("startStreaming:\(mode.rawValue)")
                    throw StreamingSetupFailure()
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    throw StreamingSetupFailure()
                },
                cancelTranscriptionSession: {
                    events.append("cancelStreaming")
                },
                insertText: { text, _, _ in
                    XCTFail("Insertion should not run when Nemotron English setup/finalization fails")
                    return .failedToInsert
                },
                beginLiveInsertion: { _ in
                    events.append("beginLiveInsertion")
                    return true
                },
                appendLiveInsertionText: { _ in
                    XCTFail("Live insertion should stay disabled when streaming setup fails")
                    return false
                },
                finalizeLiveInsertion: { _, _, _ in
                    XCTFail("Final live insertion should not run when streaming setup fails")
                    return .failedToInsert
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "")
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "beginLiveInsertion",
                "startStreaming:englishRealtimeNemotron",
                "cancelStreaming",
                "audioStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "cancelStreaming"
            ]
        )
    }

    func testHotkeyCallbackPlaysStartStopAndCompletionCuesWhenEnabled() async {
        let audioSettings = makeAudioSettings()

        var events: [String] = []
        var hotkeyTrigger: (() -> Void)?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { onTrigger in
                    hotkeyTrigger = onTrigger
                    return .installed
                },
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
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello world"
                },
                insertText: { _, _, _ in
                    events.append("insertText")
                    return .insertedAccessibility
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        XCTAssertNotNil(hotkeyTrigger)
        await appState.bootstrap()

        hotkeyTrigger?()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)

        hotkeyTrigger?()
        await settleQueuedTasks()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(
            events,
            [
                "cue:recordingWillStart",
                "audioStart",
                "audioStop",
                "cue:recordingDidStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "insertText",
                "copy",
                "cue:pipelineDidComplete"
            ]
        )
    }

    func testHotkeyCallbackSkipsAudioCuesWhenDisabled() async {
        let audioSettings = makeAudioSettings()
        audioSettings.playAudioCues = false

        var events: [String] = []
        var hotkeyTrigger: (() -> Void)?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { onTrigger in
                    hotkeyTrigger = onTrigger
                    return .installed
                },
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
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                finalizeTranscriptionSession: { mode, _, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .englishRealtimeNemotron)
                    XCTAssertNil(fallbackSamples)
                    return "hello world"
                },
                insertText: { _, _, _ in
                    events.append("insertText")
                    return .insertedAccessibility
                },
                copyTextToClipboard: { _ in
                    events.append("copy")
                }
            ),
            bootstrapsOnInit: false
        )

        XCTAssertNotNil(hotkeyTrigger)
        await appState.bootstrap()

        hotkeyTrigger?()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)

        hotkeyTrigger?()
        await settleQueuedTasks()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "audioStop",
                "prepareRecording",
                "finalize:englishRealtimeNemotron",
                "insertText",
                "copy"
            ]
        )
    }

    func testMultilingualWhisperModeUsesWhisperFinalizationPath() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionMode = .multilingualWhisper

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
                        trailingLiveSamples: [0.1, 0.2, 0.3]
                    )
                },
                prepareRecordingForTranscription: { _, _ in
                    events.append("prepareRecording")
                    return PreparedRecording(
                        samples: Array(repeating: 0.25, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                startTranscriptionSession: { mode in
                    events.append("startStreaming:\(mode.rawValue)")
                },
                finalizeTranscriptionSession: { mode, trailingSamples, fallbackSamples in
                    events.append("finalize:\(mode.rawValue)")
                    XCTAssertEqual(mode, .multilingualWhisper)
                    XCTAssertEqual(trailingSamples, [0.1, 0.2, 0.3])
                    XCTAssertEqual(fallbackSamples?.count, 8_000)
                    return "hola mundo"
                },
                insertText: { text, _, _ in
                    events.append("insertText:\(text)")
                    return .insertedAccessibility
                },
                copyTextToClipboard: { text in
                    events.append("copy:\(text)")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "hola mundo")
        XCTAssertEqual(
            events,
            [
                "audioStart",
                "audioStop",
                "startStreaming:multilingualWhisper",
                "prepareRecording",
                "finalize:multilingualWhisper",
                "insertText:hola mundo",
                "copy:hola mundo"
            ]
        )
    }

    func testTranscriptionModeDidChangePreparesNewBackendLazily() async {
        let audioSettings = makeAudioSettings()
        var preparedModes: [TranscriptionMode] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: { mode in
                    preparedModes.append(mode)
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/\(mode.rawValue).bin"),
                        readyDisplayName: mode.modelSetupName
                    )
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.prepareModelIfNeeded()
        XCTAssertEqual(preparedModes, [.englishRealtimeNemotron])

        audioSettings.transcriptionMode = .multilingualWhisper
        await appState.transcriptionModeDidChange()

        XCTAssertEqual(preparedModes, [.englishRealtimeNemotron, .multilingualWhisper])
        XCTAssertTrue(appState.modelReady)
        XCTAssertEqual(appState.selectedTranscriptionMode, .multilingualWhisper)
    }

    func testRefreshPermissionsDoesNotReinstallRegisteredShortcut() {
        let audioSettings = makeAudioSettings()
        var accessibilityGranted = false
        var installCount = 0

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { _ in
                    installCount += 1
                    return .installed
                },
                permissionSnapshot: {
                    PermissionSnapshot(
                        microphone: Self.grantedPermission(),
                        accessibility: accessibilityGranted ? Self.grantedPermission() : Self.requiredPermission()
                    )
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        XCTAssertEqual(installCount, 1)

        accessibilityGranted = true
        appState.refreshPermissions()

        XCTAssertEqual(installCount, 1)
        XCTAssertTrue(appState.canUseGlobalTrigger)
    }

    func testFailedShortcutRegistrationUsesRetryCopy() async {
        let audioSettings = makeAudioSettings()

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { _ in
                    .failedToRegister
                },
                finalizeTranscriptionSession: { _, _, _ in "hello world" },
                insertText: { _, _, _ in .insertedAccessibility },
                copyTextToClipboard: { _ in }
            ),
            bootstrapsOnInit: false
        )

        await appState.prepareModelIfNeeded()
        appState.refreshPermissions()

        XCTAssertFalse(appState.canUseGlobalTrigger)
        XCTAssertEqual(appState.hotkeyListenerStatus, .failedToRegister)
        XCTAssertEqual(
            appState.statusMessage,
            "Use the button to dictate now. spk could not register Cmd+Shift+Space; reopen spk and try again."
        )
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
        prepareTranscription: @escaping (TranscriptionMode) async throws -> TranscriptionPreparation = { mode in
            TranscriptionPreparation(
                resolvedModelURL: URL(fileURLWithPath: "/tmp/\(mode.rawValue).bin"),
                readyDisplayName: mode.modelSetupName
            )
        },
        prepareRecordingForTranscription: @escaping (URL, Double) async throws -> PreparedRecording = { _, _ in
            PreparedRecording(
                samples: Array(repeating: 0.2, count: 8_000),
                duration: 0.5,
                rmsLevel: 0.2
            )
        },
        startTranscriptionSession: @escaping (TranscriptionMode) async throws -> Void = { _ in },
        appendStreamingSamples: @escaping ([Float]) async throws -> StreamingTranscriptionUpdate? = { _ in nil },
        finalizeTranscriptionSession: @escaping (TranscriptionMode, [Float], [Float]?) async throws -> String,
        cancelTranscriptionSession: @escaping () async -> Void = {},
        insertText: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome,
        beginLiveInsertion: @escaping (TextInsertionService.Target?) -> Bool = { _ in false },
        appendLiveInsertionText: @escaping (String) -> Bool = { _ in false },
        finalizeLiveInsertion: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome = { _, _, _ in .failedToInsert },
        cancelLiveInsertion: @escaping () -> Void = {},
        copyTextToClipboard: @escaping (String) -> Void,
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
            modelDirectoryURL: { _ in URL(fileURLWithPath: "/tmp") },
            startTranscriptionSession: startTranscriptionSession,
            appendStreamingSamples: appendStreamingSamples,
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

    private static func requiredPermission() -> PermissionState {
        PermissionState(
            isGranted: false,
            description: "Required",
            explanation: "",
            canRequestDirectly: false,
            needsSystemSettings: true
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
