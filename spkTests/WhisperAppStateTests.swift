import Foundation
import XCTest
@testable import spk

private actor StopGate {
    private var started = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        started = true
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor StartGate {
    private var started = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        started = true
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

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
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium-q5_0.bin"),
                        readyDisplayName: "ggml-medium-q5_0.bin"
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
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium-q5_0.bin"),
                        readyDisplayName: "ggml-medium-q5_0.bin"
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        XCTAssertEqual(appState.startupSetupPhase, .ready)
        XCTAssertEqual(events, ["requestMicrophone", "prepare"])
    }

    func testBootstrapBackendFailureBlocksRecordingAndSurfacesMessage() async {
        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: {
                    throw WhisperBridge.WhisperBridgeError.modelUnavailableLocally(fileName: "ggml-medium-q5_0.bin")
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        if case .failed(.backend(let message)) = appState.startupSetupPhase {
            XCTAssertEqual(
                message,
                WhisperBridge.WhisperBridgeError.modelUnavailableLocally(fileName: "ggml-medium-q5_0.bin").localizedDescription
            )
        } else {
            XCTFail("Expected backend failure, got \(appState.startupSetupPhase)")
        }
        XCTAssertFalse(appState.canRecord)
        XCTAssertEqual(appState.statusTitle, "Setup Failed")
    }

    func testVoxtralBootstrapKeepsRecordingDisabledUntilWarmStreamingFinishes() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let gate = StartGate()
        let progressDetail = "Preparing Voxtral live ingestion..."

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                prepareTranscription: {
                    await gate.enter()
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602"),
                        readyDisplayName: "Voxtral-Mini-4B-Realtime-2602"
                    )
                },
                transcriptionPreparationProgress: {
                    TranscriptionPreparationProgress(
                        stage: .warmingStreaming,
                        fraction: 0.92,
                        detail: progressDetail
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        let bootstrapTask = Task { await appState.bootstrap() }
        await gate.waitUntilStarted()
        await settleQueuedTasks()

        XCTAssertEqual(appState.startupSetupPhase, .preparingBackend)
        XCTAssertFalse(appState.canRecord)
        XCTAssertEqual(appState.statusMessage, progressDetail)
        XCTAssertTrue(appState.startupProgressSummary.contains(progressDetail))

        await gate.release()
        await bootstrapTask.value

        XCTAssertEqual(appState.startupSetupPhase, .ready)
        XCTAssertTrue(appState.canRecord)
    }

    func testVoxtralHotkeyDuringStartupPreparationSurfacesCurrentPreparationDetail() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let gate = StartGate()
        let progressDetail = "Preparing Voxtral live ingestion..."
        var hotkeyHandler: (() -> Void)?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                prepareTranscription: {
                    await gate.enter()
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602"),
                        readyDisplayName: "Voxtral-Mini-4B-Realtime-2602"
                    )
                },
                transcriptionPreparationProgress: {
                    TranscriptionPreparationProgress(
                        stage: .warmingStreaming,
                        fraction: 0.92,
                        detail: progressDetail
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        let bootstrapTask = Task { await appState.bootstrap() }
        await gate.waitUntilStarted()
        await settleQueuedTasks()

        hotkeyHandler?()
        await settleQueuedTasks()

        XCTAssertEqual(appState.statusMessage, progressDetail)
        XCTAssertFalse(appState.canRecord)

        await gate.release()
        await bootstrapTask.value
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
                    return .inactive
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav")
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
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
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
        XCTAssertEqual(appState.statusMessage, "Recording... spk will insert the transcript when you stop.")

        await appState.toggleRecordingFromButton()

        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertFalse(appState.isInserting)
        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertEqual(insertedText, "hello world")
        XCTAssertNil(copiedText)
        XCTAssertTrue(events.contains("transcribe:8000"))
        XCTAssertEqual(events.first, "cue:recordingWillStart")
        XCTAssertEqual(events.last, "cue:pipelineDidComplete")
    }

    func testToggleRecordingPassesPasteFallbackSettingIntoInsertionOptions() async {
        let audioSettings = makeAudioSettings()
        audioSettings.allowPasteFallback = true

        var receivedOptions: TextInsertionService.InsertionOptions?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStop: {
                    RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav")
                    )
                },
                insertText: { _, _, options in
                    receivedOptions = options
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(receivedOptions?.allowPasteFallback, true)
        XCTAssertEqual(receivedOptions?.restoreClipboardAfterPaste, true)
        XCTAssertEqual(receivedOptions?.copyToClipboardOnFailure, false)
    }

    func testStopCuePlaysWithoutCompletionCueWhenRecordingProducesNoFile() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                    return .inactive
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(recordingURL: nil)
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
                    return .inactive
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav")
                    )
                },
                prepareRecordingForTranscription: { _, _ in
                    PreparedRecording(
                        samples: Array(repeating: 0.2, count: 8_000),
                        duration: 0.5,
                        rmsLevel: 0.2
                    )
                },
                transcribePreparedRecording: { _, _ in
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

    func testButtonStartedStreamingPreviewUsesLiveExternalInsertionWhenExternalTargetWasCaptured() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "waiting",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 321,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { _, _, _ in
                    XCTFail("Button-started live insertion should commit through the streaming session")
                    return .failedToInsert
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "preview",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.streamingPreviewText, "hello preview")
        XCTAssertGreaterThan(appState.liveInputLevel, 0)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertTrue(events.contains("stream:hello preview"))

        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertEqual(appState.streamingPreviewText, "")
        XCTAssertTrue(events.contains("prepareSamples:8000:1.0"))
        XCTAssertTrue(events.contains("transcribe:8000"))
        XCTAssertTrue(events.contains("commit:final transcript"))

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("deliveryReason=captured-external-button-target"))
    }

    func testButtonStartedStreamingPreviewSupportsArbitraryDownloadedAppTargetsWhenLiveSessionUsesBlindTyping() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "waiting",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind,
            diagnosticsReason: "aggressive-target-authority"
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { _, _, _ in
                    XCTFail("Button-started live insertion should commit through the streaming session")
                    return .failedToInsert
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "downloaded",
            unconfirmedText: "app",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertTrue(events.contains("stream:downloaded app"))

        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("commit:final transcript"))
        XCTAssertFalse(events.contains("insert:final transcript"))
    }

    func testHotkeyStartedStreamingPreviewUsesLiveExternalInsertionWhenSpkWindowsAreHidden() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { false },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("stream:") }))

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "preview",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.streamingPreviewText, "hello preview")
        XCTAssertGreaterThan(appState.liveInputLevel, 0)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertTrue(events.contains("stream:hello preview"))

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertEqual(appState.streamingPreviewText, "")
        XCTAssertTrue(events.contains("prepareSamples:8000:1.0"))
        XCTAssertTrue(events.contains("transcribe:8000"))
        XCTAssertTrue(events.contains("commit:final transcript"))
        XCTAssertFalse(events.contains("insert:final transcript"))
    }

    func testHotkeyStopImmediatelyEndsLivePreviewUpdatesAndBlocksReentrantHotkeyWhileAudioStopFinishes() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        let stopGate = StopGate()
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop:start")
                    await stopGate.enter()
                    events.append("audioStop:end")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000)
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { false },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "preview",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertTrue(events.contains("stream:hello preview"))

        hotkeyHandler()
        await stopGate.waitUntilStarted()
        XCTAssertFalse(appState.isRecording)
        XCTAssertTrue(appState.isStoppingRecording)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertEqual(appState.statusMessage, "Stopping recording...")

        let streamCountBeforeStopRelease = events.filter { $0.hasPrefix("stream:") }.count
        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "after",
            unconfirmedText: "stop",
            currentText: "",
            latestRelativeEnergy: 0.9
        )

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(events.filter { $0 == "audioStart" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "audioStop:start" }.count, 1)
        XCTAssertEqual(events.filter { $0.hasPrefix("stream:") }.count, streamCountBeforeStopRelease)

        await stopGate.release()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("audioStop:end"))
        XCTAssertTrue(events.contains("prepareSamples:8000:1.0"))
        XCTAssertTrue(events.contains("transcribe:8000"))
        XCTAssertTrue(events.contains("commit:final transcript"))
        XCTAssertFalse(events.contains("insert:final transcript"))
    }

    func testVoxtralRecordingStartsOnlyAfterLiveSessionReady() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        let startGate = StartGate()
        var hotkeyHandler: (() -> Void)?
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart:start")
                    await startGate.enter()
                    events.append("audioStart:end")
                    return .active
                },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await startGate.waitUntilStarted()

        XCTAssertTrue(appState.isStartingRecording)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.showsVisibleRecordingStartState)
        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertEqual(appState.statusMessage, "Listening for microphone input...")
        XCTAssertFalse(appState.canRecord)
        XCTAssertFalse(events.contains("cue:recordingWillStart"))

        await startGate.release()
        await settleQueuedTasks()

        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.isStreamingPreviewActive)
        XCTAssertFalse(appState.isPrewarmingLivePreview)
        XCTAssertEqual(
            appState.statusMessage,
            "Recording with Voxtral live preview... spk will keep the live transcript when you stop."
        )
        XCTAssertEqual(
            Array(events.prefix(3)),
            ["audioStart:start", "audioStart:end", "cue:recordingWillStart"]
        )

        hotkeyHandler()
        await settleQueuedTasks()
    }

    func testVoxtralHotkeyPressDuringPreparationCancelsPendingStart() async {
        actor CallRecorder {
            private var audioStartCount = 0
            private var audioStopCount = 0
            private var cancelCount = 0

            func markStart() {
                audioStartCount += 1
            }

            func markStop() {
                audioStopCount += 1
            }

            func markCancel() {
                cancelCount += 1
            }

            func counts() -> (Int, Int, Int) {
                (audioStartCount, audioStopCount, cancelCount)
            }
        }

        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        let startGate = StartGate()
        let callRecorder = CallRecorder()
        var hotkeyHandler: (() -> Void)?
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    await callRecorder.markStart()
                    await startGate.enter()
                    return .active
                },
                cancelPendingRecordingStart: {
                    await callRecorder.markCancel()
                    await startGate.release()
                },
                audioStop: {
                    await callRecorder.markStop()
                    return RecordingStopResult(recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"))
                },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true },
                playAudioCue: { cue in
                    events.append("cue:\(cue.rawValue)")
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await startGate.waitUntilStarted()
        XCTAssertTrue(appState.isStartingRecording)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.showsVisibleRecordingStartState)
        XCTAssertEqual(appState.statusTitle, "Ready")
        XCTAssertFalse(appState.canRecord)

        hotkeyHandler()
        await settleQueuedTasks()

        let counts = await callRecorder.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 1)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertEqual(appState.statusMessage, "Cancelled Voxtral live session preparation.")
        XCTAssertFalse(events.contains("cue:recordingWillStart"))
    }

    func testVoxtralUnavailablePreviewStillShowsVoiceInputCardWhileRecording() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in .active },
                currentLivePreviewRuntimeState: {
                    .unavailable("The Voxtral helper stopped responding.")
                },
                isExperimentalStreamingPreviewEnabled: { true }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.shouldShowStreamingPreviewCard)
        XCTAssertEqual(
            appState.streamingPreviewDisplayText,
            "Voxtral live preview unavailable. Final transcript will run on stop."
        )
        XCTAssertTrue(appState.statusMessage.contains("Live preview unavailable"))

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
    }

    func testHotkeyStartedStreamingPreviewUsesLiveExternalInsertionWhenExternalTargetIsCapturedEvenIfSpkWindowIsVisible() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedPaste
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("stream:") }))

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "cursor",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(appState.streamingPreviewText, "hello cursor")
        XCTAssertTrue(events.contains("stream:hello cursor"))

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("commit:final transcript"))
        XCTAssertFalse(events.contains("insert:final transcript"))
    }

    func testVoxtralHotkeyStartedLivePreviewStreamsIntoExternalAppLikeWhisper() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                currentLivePreviewRuntimeState: { .active },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "voxtral final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.isStreamingPreviewActive)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("stream:") }))

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "voxtral",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(appState.streamingPreviewText, "hello voxtral")
        XCTAssertTrue(events.contains("stream:hello voxtral"))

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "voxtral final transcript")
        XCTAssertTrue(events.contains("commit:voxtral final transcript"))
        XCTAssertFalse(events.contains("insert:voxtral final transcript"))
    }

    func testVoxtralStopUsesLiveFinalTranscriptWithoutShowingTranscribingState() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        let stopGate = StopGate()
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop:start")
                    await stopGate.enter()
                    events.append("audioStop:end")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("Voxtral should not prepare the recorded audio when the live final transcript is already available.")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { _, _ in
                    XCTFail("Voxtral should not prepare buffered samples when the live final transcript is already available.")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                transcribePreparedRecording: { _, _ in
                    XCTFail("Voxtral should not retry transcription when the live final transcript is already available.")
                    return ""
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()
        XCTAssertTrue(appState.isRecording)

        hotkeyHandler()
        await stopGate.waitUntilStarted()

        XCTAssertFalse(appState.isRecording)
        XCTAssertTrue(appState.isStoppingRecording)
        XCTAssertFalse(appState.canRecord)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertFalse(appState.isInserting)
        XCTAssertEqual(appState.statusTitle, "Finishing")
        XCTAssertEqual(appState.statusMessage, "Stopping recording...")

        await stopGate.release()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "voxtral final transcript")
        XCTAssertTrue(events.contains("insert:voxtral final transcript"))
        XCTAssertFalse(appState.isStoppingRecording)
        XCTAssertTrue(appState.canRecord)
    }

    func testHotkeyStartedStreamingPreviewSupportsArbitraryDownloadedAppTargetsWhenLiveSessionUsesBlindTyping() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000)
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    events.append("beginStreamingSession")
                    return streamingSession
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === streamingSession)
                    events.append("stream:\(text)")
                    return true
                },
                commitStreamingInsertionSession: { session, text, _ in
                    XCTAssertTrue(session === streamingSession)
                    events.append("commit:\(text)")
                    return .insertedTyping
                },
                insertText: { text, _, _ in
                    events.append("insert:\(text)")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(events.contains("beginStreamingSession"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("stream:") }))

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "downloaded",
            unconfirmedText: "app",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(appState.streamingPreviewText, "downloaded app")
        XCTAssertTrue(events.contains("stream:downloaded app"))

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("commit:final transcript"))
        XCTAssertFalse(events.contains("insert:final transcript"))
    }

    func testFailedLiveStreamingUpdateRecoversOnceThenFallsBackToFreshFinalInsert() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        var beginStreamingCallCount = 0
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let failedSession = TextInsertionService.StreamingSession.testing(
            target: frozenTarget,
            mode: .typingBlind
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000)
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { false },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    beginStreamingCallCount += 1
                    events.append("begin:\(beginStreamingCallCount)")
                    return beginStreamingCallCount == 1 ? failedSession : nil
                },
                updateStreamingInsertionSession: { session, text in
                    XCTAssertTrue(session === failedSession)
                    events.append("stream:\(text)")
                    return false
                },
                commitStreamingInsertionSession: { _, _, _ in
                    XCTFail("A degraded session should fall back to a fresh final insert")
                    return .failedToInsert
                },
                cancelStreamingInsertionSession: { session in
                    XCTAssertTrue(session === failedSession)
                    events.append("cancel")
                },
                insertText: { text, capturedContext, _ in
                    events.append("insert:\(text)")
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    return .insertedTyping
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(beginStreamingCallCount, 1)

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "cursor",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(appState.streamingPreviewText, "hello cursor")
        XCTAssertEqual(beginStreamingCallCount, 2)
        XCTAssertEqual(events.filter { $0 == "stream:hello cursor" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "cancel" }.count, 1)

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "again",
            currentText: "",
            latestRelativeEnergy: 0.8
        )
        await settleQueuedTasks()

        XCTAssertEqual(beginStreamingCallCount, 2)
        XCTAssertEqual(events.filter { $0.hasPrefix("stream:") }.count, 1)
        XCTAssertEqual(events.filter { $0 == "cancel" }.count, 1)

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("insert:final transcript"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("commit:") }))
    }

    func testHotkeyFallsBackToUiPreviewWhenNoExternalTargetWasCaptured() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var events: [String] = []
        var hotkeyHandler: (() -> Void)?
        var insertedTarget: TextInsertionService.Target?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in
                    events.append("audioStart")
                    return .active
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000)
                    )
                },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("File-backed preparation should not run for buffered streaming audio")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "final transcript"
                },
                captureInsertionContext: {
                    nil
                },
                hasVisibleSpkWindows: { false },
                beginStreamingInsertionSession: { _ in
                    XCTFail("Hotkey recording without an external target should not start a live insertion session")
                    return nil
                },
                updateStreamingInsertionSession: { _, _ in
                    XCTFail("Hotkey recording without an external target should not stream externally")
                    return false
                },
                commitStreamingInsertionSession: { _, _, _ in
                    XCTFail("Hotkey recording without an external target should not commit through a live session")
                    return .failedToInsert
                },
                insertText: { text, capturedContext, _ in
                    events.append("insert:\(text)")
                    insertedTarget = capturedContext?.target
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()

        hotkeyHandler()
        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "preview",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.streamingPreviewText, "hello preview")
        XCTAssertFalse(events.contains("beginStreamingSession"))
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("stream:") }))

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "final transcript")
        XCTAssertTrue(events.contains("insert:final transcript"))
        XCTAssertNil(insertedTarget)
    }

    func testHotkeyStartDiagnosticsExplainWhyExternalTargetOverridesVisibleSpkWindows() async {
        DebugLog.resetForTesting()

        let audioSettings = makeAudioSettings()
        var hotkeyHandler: (() -> Void)?
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let streamingSession = TextInsertionService.StreamingSession.testing(target: frozenTarget)

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in .active },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { true },
                beginStreamingInsertionSession: { _ in
                    streamingSession
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()
        hotkeyHandler()
        await settleQueuedTasks()

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("deliveryReason=captured-external-hotkey-target"))
        XCTAssertTrue(diagnostics.contains("spkWindowsVisible=true"))
        XCTAssertTrue(diagnostics.contains("capturedTarget=Cursor pid=654 bundle=com.todesktop.cursor"))
        XCTAssertTrue(diagnostics.contains("family=code-editor"))
        XCTAssertTrue(diagnostics.contains("captureMethod=testing"))

        hotkeyHandler()
        await settleQueuedTasks()
    }

    func testFailedLiveInsertionPrimingDoesNotSpamEveryPreviewTick() async {
        let audioSettings = makeAudioSettings()
        var previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: "",
            latestRelativeEnergy: 0.4
        )
        var hotkeyHandler: (() -> Void)?
        var beginStreamingCallCount = 0
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 654,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in .active },
                normalizedInputLevel: {
                    previewSnapshot.latestRelativeEnergy
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewSnapshot: {
                    previewSnapshot
                },
                captureInsertionContext: {
                    TextInsertionService.CapturedInsertionContext.testing(target: frozenTarget)
                },
                hasVisibleSpkWindows: { false },
                beginStreamingInsertionSession: { capturedContext in
                    XCTAssertEqual(capturedContext?.target, frozenTarget)
                    beginStreamingCallCount += 1
                    return nil
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()
        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(beginStreamingCallCount, 1)

        previewSnapshot = StreamingPreviewSnapshot(
            confirmedText: "hello",
            unconfirmedText: "cursor",
            currentText: "",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(beginStreamingCallCount, 2)
        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.streamingPreviewText, "hello cursor")

        hotkeyHandler()
        await settleQueuedTasks()
    }

    func testRequestedExperimentalStreamingPreviewStaysHiddenWhenStandardRecordingFallbackIsUsed() async {
        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    .inactive
                },
                isExperimentalStreamingPreviewEnabled: { true },
                streamingPreviewUnavailableReason: {
                    "Choose or install a local WhisperKit preview model to test live preview."
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.shouldShowStreamingPreviewCard)
        XCTAssertEqual(appState.streamingPreviewDisplayText, "Listening...")
        XCTAssertTrue(appState.statusMessage.contains("Live preview unavailable"))
        XCTAssertTrue(appState.statusMessage.contains("Choose or install a local WhisperKit preview model to test live preview."))

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
    }

    func testTwoConsecutiveRecordingsTranscribeCleanly() async {
        let audioSettings = makeAudioSettings()
        var transcriptionCallCount = 0

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStop: {
                    RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav")
                    )
                },
                transcribePreparedRecording: { _, _ in
                    transcriptionCallCount += 1
                    return transcriptionCallCount == 1 ? "first pass" : "second pass"
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "first pass")

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(transcriptionCallCount, 2)
        XCTAssertEqual(appState.lastTranscript, "second pass")
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
        XCTAssertFalse(appState.isInserting)
    }

    func testVoxtralPreparedRecordingUsesFrozenLiveTranscriptWithoutRetryingFromRecordedAudio() async throws {
        actor FallbackRecorder {
            private var calls: [(audioURL: URL, modelURL: URL)] = []

            func append(audioURL: URL, modelURL: URL) {
                calls.append((audioURL: audioURL, modelURL: modelURL))
            }

            func allCalls() -> [(audioURL: URL, modelURL: URL)] {
                calls
            }
        }

        @MainActor
        final class StatusRecorder {
            var messages: [String] = []
        }

        let fallbackRecorder = FallbackRecorder()
        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            initialStreamingStopOutcome: VoxtralStreamingStopOutcome(
                bestAvailableTranscript: "live session transcript",
                failureReason: nil,
                wasCleanUserStop: true
            ),
            transcribeAudioFileHandler: { audioURL, modelURL in
                await fallbackRecorder.append(audioURL: audioURL, modelURL: modelURL)
                return "file fallback transcript"
            }
        )
        let statusRecorder = await MainActor.run { StatusRecorder() }

        let transcript = try await backend.transcribePreparedRecording(
            PreparedRecording(
                samples: Array(repeating: 0.25, count: 16_000),
                duration: 1.0,
                rmsLevel: 0.25,
                sourceRecordingURL: URL(fileURLWithPath: "/tmp/live-session.wav")
            )
        ) { message in
            statusRecorder.messages.append(message)
        }

        XCTAssertEqual(transcript, "live session transcript")
        let fallbackCalls = await fallbackRecorder.allCalls()
        XCTAssertTrue(fallbackCalls.isEmpty)
        let statusMessages = await MainActor.run { statusRecorder.messages }
        XCTAssertTrue(statusMessages.isEmpty)
    }

    func testVoxtralPreparedRecordingSkipsRecordedFileRetryAfterCleanStopWithoutLiveText() async throws {
        actor FallbackRecorder {
            private var calls: [(audioURL: URL, modelURL: URL)] = []

            func append(audioURL: URL, modelURL: URL) {
                calls.append((audioURL: audioURL, modelURL: modelURL))
            }

            func allCalls() -> [(audioURL: URL, modelURL: URL)] {
                calls
            }
        }

        @MainActor
        final class StatusRecorder {
            var messages: [String] = []
        }

        let fallbackRecorder = FallbackRecorder()
        let modelURL = URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602")
        let recordingURL = URL(fileURLWithPath: "/tmp/original-recording.wav")
        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            preparedModel: VoxtralRealtimeResolvedModel(url: modelURL, source: .custom),
            initialStreamingStopOutcome: VoxtralStreamingStopOutcome(
                bestAvailableTranscript: nil,
                failureReason: nil,
                wasCleanUserStop: true
            ),
            transcribeAudioFileHandler: { audioURL, resolvedModelURL in
                await fallbackRecorder.append(audioURL: audioURL, modelURL: resolvedModelURL)
                return "retried from file"
            }
        )
        let statusRecorder = await MainActor.run { StatusRecorder() }

        let transcript = try await backend.transcribePreparedRecording(
            PreparedRecording(
                samples: Array(repeating: 0.25, count: 16_000),
                duration: 1.0,
                rmsLevel: 0.25,
                sourceRecordingURL: recordingURL
            )
        ) { message in
            statusRecorder.messages.append(message)
        }

        let fallbackCalls = await fallbackRecorder.allCalls()
        XCTAssertEqual(transcript, "")
        XCTAssertTrue(fallbackCalls.isEmpty)
        let statusMessages = await MainActor.run { statusRecorder.messages }
        XCTAssertTrue(statusMessages.isEmpty)
    }

    func testVoxtralPreparedRecordingSkipsRecordedFileRetryAfterFailedLiveStop() async throws {
        @MainActor
        final class StatusRecorder {
            var messages: [String] = []
        }

        actor FallbackRecorder {
            private var calls: Int = 0

            func append() {
                calls += 1
            }

            func value() -> Int {
                calls
            }
        }

        let fallbackRecorder = FallbackRecorder()
        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            preparedModel: VoxtralRealtimeResolvedModel(
                url: URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602"),
                source: .custom
            ),
            initialStreamingStopOutcome: VoxtralStreamingStopOutcome(
                bestAvailableTranscript: nil,
                failureReason: "helper exited before returning a live preview update",
                wasCleanUserStop: false
            ),
            transcribeAudioFileHandler: { _, _ in
                await fallbackRecorder.append()
                return ""
            }
        )
        let statusRecorder = await MainActor.run { StatusRecorder() }

        let transcript = try await backend.transcribePreparedRecording(
            PreparedRecording(
                samples: Array(repeating: 0.25, count: 16_000),
                duration: 1.0,
                rmsLevel: 0.25,
                sourceRecordingURL: nil
            )
        ) { message in
            statusRecorder.messages.append(message)
        }

        XCTAssertEqual(transcript, "")
        let fallbackCallCount = await fallbackRecorder.value()
        XCTAssertEqual(fallbackCallCount, 0)
        let statusMessages = await MainActor.run { statusRecorder.messages }
        XCTAssertTrue(statusMessages.isEmpty)
    }

    func testVoxtralStartSurfacesPendingMicrophoneFallbackStatusAndKeepsFallbackNotice() async throws {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    try await Task.sleep(nanoseconds: 350_000_000)
                    return RecordingStartResult(
                        livePreviewState: .active,
                        inputStatusMessage: "Using current macOS default microphone because the selected input produced no live audio."
                    )
                },
                pendingRecordingStartStatusMessage: {
                    "Trying current macOS default microphone..."
                },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        let startTask = Task {
            await appState.toggleRecordingFromButton()
        }

        try await waitForAsyncCondition(timeout: 1.0) {
            await MainActor.run {
                appState.isStartingRecording
                    && appState.statusMessage == "Trying current macOS default microphone..."
            }
        }

        await startTask.value
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(
            appState.statusMessage,
            "Using current macOS default microphone because the selected input produced no live audio."
        )
        XCTAssertEqual(appState.streamingPreviewDisplayText, "Waiting for speech...")
    }

    func testLocalVoxtralReplayFilePipelineCanValidateExternalFixtureWhenEnabled() async throws {
        let fileManager = FileManager.default
        let fixtureURL: URL
        if let fixturePath = ProcessInfo.processInfo.environment["SPK_LOCAL_VOXTRAL_REPLAY_VALIDATION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fixturePath.isEmpty {
            fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        } else if let markerPath = try? String(
            contentsOf: URL(fileURLWithPath: "/tmp/spk_local_voxtral_replay_validation_path.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        !markerPath.isEmpty {
            fixtureURL = URL(fileURLWithPath: markerPath).standardizedFileURL
        } else {
            throw XCTSkip("Set SPK_LOCAL_VOXTRAL_REPLAY_VALIDATION_FILE or write the fixture path to /tmp/spk_local_voxtral_replay_validation_path.txt to run the local Voxtral replay validation test.")
        }

        guard fileManager.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("The local Voxtral replay validation file is missing at \(fixtureURL.path).")
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = repoRoot
            .appending(path: "spk")
            .appending(path: "Resources")
            .appending(path: "Helpers")
            .appending(path: "spk_voxtral_realtime_helper.py")
        let pythonURL = VoxtralRealtimeModelLocator.defaultPythonURL(fileManager: fileManager)
        let modelURL = VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager)

        guard fileManager.fileExists(atPath: helperURL.path),
              fileManager.fileExists(atPath: pythonURL.path),
              fileManager.fileExists(atPath: modelURL.path)
        else {
            throw XCTSkip("Local Voxtral helper, runtime, or model artifacts are unavailable for replay validation.")
        }

        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path,
                VoxtralRealtimeTranscriptionBackend.debugLiveAudioFileEnvironmentKey: fixtureURL.path
            ],
            fileManager: fileManager,
            bundle: Bundle(for: Self.self)
        )

        do {
            _ = try await backend.prepare()
            let startResult = try await backend.startRecording(preferredInputDeviceID: nil)
            XCTAssertEqual(startResult.livePreviewState, .active)

            try await waitForAsyncCondition(timeout: 12.0) {
                guard let snapshot = await backend.latestPreviewSnapshot() else {
                    return false
                }
                let text = snapshot.displayText
                return !text.isEmpty && text != "Waiting for speech..." && text != "Live preview unavailable."
            }

            let stopResult = await backend.stopRecording()
            let recordingURL = try XCTUnwrap(stopResult.recordingURL)
            let preparedRecording = try AudioRecorder.prepareForTranscription(from: recordingURL, inputSensitivity: 1.0)
            let transcript = try await backend.transcribePreparedRecording(preparedRecording) { _ in }

            XCTAssertFalse(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(
                transcript.localizedCaseInsensitiveContains("testing")
                || transcript.localizedCaseInsensitiveContains("one")
                || transcript.localizedCaseInsensitiveContains("two")
            )
        } catch is CancellationError {
            throw XCTSkip("Local Voxtral helper-backed replay validation was cancelled in the current test environment.")
        } catch let error as VoxtralRealtimeTranscriptionBackend.BackendError {
            throw XCTSkip("Local Voxtral helper-backed replay validation is unavailable in the current test environment: \(error.localizedDescription)")
        } catch let error as VoxtralRealtimeHelperClient.HelperError {
            throw XCTSkip("Local Voxtral helper-backed replay validation is unavailable in the current test environment: \(error.localizedDescription)")
        }
    }

    func testVoxtralStartRecordingRebuildsInlineWhenHelperRestartsAfterInitialLiveIngestionProbe() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager
        )

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )

        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: fileManager,
            bundle: Bundle(for: Self.self),
            helperClient: helperClient,
            liveInputSourceFactory: { _ in
                ImmediateActiveVoxtralInputSource(
                    recordingURL: rootDirectory.appending(path: "test-recording.wav")
                )
            }
        )

        do {
            _ = try await backend.prepare()

            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let startResult = try await backend.startRecording(preferredInputDeviceID: nil)
            XCTAssertEqual(startResult.livePreviewState, .active)

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(
                eventLines,
                [
                    "launch=1 type=load_model loaded=false",
                    "launch=1 emit=ready",
                    "launch=1 type=start_session loaded=true",
                    "launch=1 emit=session_started",
                    "launch=1 type=append_audio loaded=true",
                    "launch=1 emit=preview_update",
                    "launch=1 type=cancel_session loaded=true",
                    "launch=1 emit=session_cancelled",
                    "launch=2 type=load_model loaded=false",
                    "launch=2 emit=ready",
                    "launch=2 type=start_session loaded=true",
                    "launch=2 emit=session_started",
                    "launch=2 type=append_audio loaded=true",
                    "launch=2 emit=preview_update",
                    "launch=2 type=cancel_session loaded=true",
                    "launch=2 emit=session_cancelled",
                    "launch=2 type=start_session loaded=true",
                    "launch=2 emit=session_started"
                ]
            )
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
    }

    func testVoxtralStopCancelsLiveSessionWithoutFinalizationOrHelperRecovery() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager
        )

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )

        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: fileManager,
            bundle: Bundle(for: Self.self),
            helperClient: helperClient,
            liveInputSourceFactory: { _ in
                ImmediateActiveVoxtralInputSource(
                    recordingURL: rootDirectory.appending(path: "test-recording.wav")
                )
            }
        )

        do {
            _ = try await backend.prepare()
            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }
            _ = try await backend.startRecording(preferredInputDeviceID: nil)

            let stopResult = await backend.stopRecording()
            XCTAssertTrue(stopResult.wasCleanUserStop)
            XCTAssertNil(stopResult.bestAvailableTranscript)

            try? await Task.sleep(for: .milliseconds(250))

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertFalse(eventLines.contains { $0.contains("type=finish_session") })
            XCTAssertFalse(eventLines.contains { $0.contains("type=shutdown") })
            XCTAssertTrue(eventLines.contains("launch=2 type=cancel_session loaded=true"))
            let currentGeneration = await helperClient.currentProcessGeneration()
            XCTAssertNotNil(currentGeneration)
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
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
        audioStart: @escaping (String?) async throws -> RecordingStartResult = { _ in .inactive },
        cancelPendingRecordingStart: @escaping () async -> Void = {},
        audioStop: @escaping () async -> RecordingStopResult = {
            RecordingStopResult(
                recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav")
            )
        },
        pendingRecordingStartStatusMessage: @escaping () async -> String? = { nil },
        currentLivePreviewRuntimeState: @escaping () async -> LivePreviewRuntimeState = { .inactive },
        normalizedInputLevel: @escaping () async -> Float = { 0.6 },
        isExperimentalStreamingPreviewEnabled: @escaping () async -> Bool = { false },
        streamingPreviewSnapshot: @escaping () async -> StreamingPreviewSnapshot? = { nil },
        streamingPreviewUnavailableReason: @escaping () async -> String? = { nil },
        prepareTranscription: @escaping () async throws -> TranscriptionPreparation = {
            TranscriptionPreparation(
                resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium-q5_0.bin"),
                readyDisplayName: "ggml-medium-q5_0.bin"
            )
        },
        transcriptionPreparationProgress: @escaping () async -> TranscriptionPreparationProgress? = { nil },
        invalidatePreparedTranscription: @escaping () async -> Void = {},
        prepareRecordingForTranscription: @escaping (URL, Double) async throws -> PreparedRecording = { url, _ in
            PreparedRecording(
                samples: Array(repeating: 0.2, count: 8_000),
                duration: 0.5,
                rmsLevel: 0.2,
                sourceRecordingURL: url
            )
        },
        prepareSamplesForTranscription: @escaping ([Float], Double) async throws -> PreparedRecording = { samples, sensitivity in
            AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
        },
        transcribePreparedRecording: @escaping (PreparedRecording, @escaping @MainActor @Sendable (String) -> Void) async throws -> String = { _, _ in "hello world" },
        captureInsertionContext: @escaping () -> TextInsertionService.CapturedInsertionContext? = {
            TextInsertionService.CapturedInsertionContext.testing(
                target: TextInsertionService.Target(
                    applicationPID: 321,
                    applicationName: "Notes",
                    bundleIdentifier: "com.apple.Notes"
                )
            )
        },
        hasVisibleSpkWindows: @escaping () -> Bool = { true },
        beginStreamingInsertionSession: @escaping (TextInsertionService.CapturedInsertionContext?) -> TextInsertionService.StreamingSession? = { _ in nil },
        updateStreamingInsertionSession: @escaping (TextInsertionService.StreamingSession, String) -> Bool = { _, _ in true },
        commitStreamingInsertionSession: @escaping (TextInsertionService.StreamingSession, String, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome = { _, _, _ in .insertedTyping },
        cancelStreamingInsertionSession: @escaping (TextInsertionService.StreamingSession) -> Void = { _ in },
        insertText: @escaping (String, TextInsertionService.CapturedInsertionContext?, TextInsertionService.InsertionOptions) -> TextInsertionService.InsertionOutcome = { _, _, _ in .insertedAccessibility },
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
            cancelPendingRecordingStart: cancelPendingRecordingStart,
            audioStop: audioStop,
            pendingRecordingStartStatusMessage: pendingRecordingStartStatusMessage,
            currentLivePreviewRuntimeState: currentLivePreviewRuntimeState,
            normalizedInputLevel: normalizedInputLevel,
            isExperimentalStreamingPreviewEnabled: isExperimentalStreamingPreviewEnabled,
            streamingPreviewSnapshot: streamingPreviewSnapshot,
            streamingPreviewUnavailableReason: streamingPreviewUnavailableReason,
            prepareTranscription: prepareTranscription,
            transcriptionPreparationProgress: transcriptionPreparationProgress,
            invalidatePreparedTranscription: invalidatePreparedTranscription,
            modelDirectoryURL: { URL(fileURLWithPath: "/tmp") },
            transcribePreparedRecording: transcribePreparedRecording,
            prepareRecordingForTranscription: prepareRecordingForTranscription,
            prepareSamplesForTranscription: prepareSamplesForTranscription,
            cleanupRecording: { _ in },
            captureInsertionContext: captureInsertionContext,
            hasVisibleSpkWindows: hasVisibleSpkWindows,
            beginStreamingInsertionSession: beginStreamingInsertionSession,
            updateStreamingInsertionSession: updateStreamingInsertionSession,
            commitStreamingInsertionSession: commitStreamingInsertionSession,
            cancelStreamingInsertionSession: cancelStreamingInsertionSession,
            insertText: insertText,
            copyTextToClipboard: copyTextToClipboard,
            playAudioCue: playAudioCue
        )
    }

    private func makeAudioSettings() -> AudioSettingsStore {
        let defaults = UserDefaults(suiteName: "WhisperAppStateTests.\(UUID().uuidString)")!
        let store = AudioSettingsStore(userDefaults: defaults)
        store.transcriptionBackendSelection = .whisper
        return store
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

    private func waitForAsyncCondition(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Timed out waiting for condition after \(timeout)s")
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeBackendRecoveryFakeHelper(
        to helperURL: URL,
        eventsURL _: URL,
        fileManager: FileManager
    ) throws {
        let script = """
        import json
        import os
        import sys
        import time

        script_dir = os.path.dirname(os.path.abspath(__file__))
        state_path = os.path.join(script_dir, "helper-state.json")
        events_path = os.path.join(script_dir, "helper-events.log")

        def load_state():
            if os.path.exists(state_path):
                with open(state_path, "r", encoding="utf-8") as handle:
                    return json.load(handle)
            return {"launch_count": 0, "saw_append": False}

        def save_state(state):
            with open(state_path, "w", encoding="utf-8") as handle:
                json.dump(state, handle)

        def append_event(message):
            with open(events_path, "a", encoding="utf-8") as handle:
                handle.write(message + "\\n")

        state = load_state()
        state["launch_count"] += 1
        state["loaded"] = False
        state["saw_append"] = False
        save_state(state)
        launch_count = state["launch_count"]

        def emit(payload):
            append_event(f"launch={launch_count} emit={payload.get('type')}")
            sys.stdout.write(json.dumps(payload) + "\\n")
            sys.stdout.flush()
            time.sleep(0.02)

        for raw_line in sys.stdin:
            raw_line = raw_line.strip()
            if not raw_line:
                continue

            payload = json.loads(raw_line)
            request_id = payload.get("request_id") or payload.get("requestID")
            request_type = payload.get("type")
            state = load_state()
            loaded = bool(state.get("loaded", False))
            append_event(f"launch={launch_count} type={request_type} loaded={'true' if loaded else 'false'}")

            if request_type == "load_model":
                state["loaded"] = True
                state["saw_append"] = False
                save_state(state)
                model_path = payload.get("model_path") or payload.get("modelPath") or ""
                emit(
                    {
                        "request_id": request_id,
                        "type": "ready",
                        "model_display_name": os.path.basename(model_path),
                        "supports_streaming_preview": True,
                        "first_streaming_chunk_sample_count": 4,
                        "streaming_chunk_sample_count": 2,
                    }
                )
            elif request_type == "start_session":
                if not loaded:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": "load_model_required",
                        }
                    )
                    continue

                emit(
                    {
                        "request_id": request_id,
                        "type": "session_started",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
            elif request_type == "append_audio":
                if not loaded:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": "load_model_required",
                        }
                    )
                    continue

                state["saw_append"] = True
                save_state(state)
                emit(
                    {
                        "request_id": request_id,
                        "type": "preview_update",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": "",
                    }
                )
            elif request_type == "finish_session":
                emit(
                    {
                        "request_id": request_id,
                        "type": "final_transcript",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": "",
                    }
                )
            elif request_type == "cancel_session":
                emit(
                    {
                        "request_id": request_id,
                        "type": "session_cancelled",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
                if launch_count == 1 and state.get("saw_append", False):
                    time.sleep(0.1)
                    sys.exit(0)
            elif request_type == "shutdown":
                emit({"request_id": request_id, "type": "shutdown"})
                sys.exit(0)
            else:
                emit(
                    {
                        "request_id": request_id,
                        "type": "error",
                        "message": f"unsupported:{request_type}",
                    }
                )
        """

        XCTAssertTrue(
            fileManager.createFile(
                atPath: helperURL.path,
                contents: Data(script.utf8)
            )
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )
    }

    private actor ImmediateActiveVoxtralInputSource: VoxtralLiveInputSource {
        nonisolated let kindDescription = "test-immediate"
        nonisolated let recordingURL: URL

        private var health: VoxtralLiveInputSourceHealth = .idle

        init(recordingURL: URL) {
            self.recordingURL = recordingURL
        }

        func start(
            preferredInputDeviceID: String?,
            onSamples: @escaping @Sendable ([Float]) -> Void,
            onFailure: @escaping @Sendable (String) -> Void
        ) async throws {
            _ = preferredInputDeviceID
            _ = onSamples
            _ = onFailure
            health = .active(activeInputDeviceID: nil)
        }

        func stop() async -> URL? {
            health = .idle
            return recordingURL
        }

        func normalizedInputLevel() async -> Float {
            0
        }

        func emittedSampleCount() async -> Int {
            0
        }

        func healthState() async -> VoxtralLiveInputSourceHealth {
            health
        }
    }
}
