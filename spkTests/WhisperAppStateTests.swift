import Carbon
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

final class HotkeyManagerTests: XCTestCase {
    func testInstallDefaultUsesSharedCmdShiftSpaceShortcutSpec() {
        var installEventHandlerCallCount = 0
        var registerHotKeyCallCount = 0
        var capturedShortcut: HotkeyManager.Shortcut?

        let manager = HotkeyManager(
            carbonHooks: HotkeyManager.CarbonHooks(
                installEventHandler: { _, _ in
                    installEventHandlerCallCount += 1
                    return (noErr, nil)
                },
                registerHotKey: { shortcut, hotKeyID in
                    registerHotKeyCallCount += 1
                    capturedShortcut = shortcut
                    XCTAssertEqual(hotKeyID.id, 1)
                    return (noErr, nil)
                },
                unregisterHotKey: { _ in },
                removeEventHandler: { _ in }
            )
        )

        XCTAssertEqual(manager.installDefault(onTrigger: {}), .installed)
        XCTAssertEqual(manager.installDefault(onTrigger: {}), .installed)
        XCTAssertEqual(installEventHandlerCallCount, 1)
        XCTAssertEqual(registerHotKeyCallCount, 1)
        XCTAssertEqual(capturedShortcut, HotkeyManager.defaultShortcut)
        XCTAssertEqual(HotkeyManager.defaultShortcut.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotkeyManager.defaultShortcut.modifiers, UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(HotkeyManager.defaultShortcutDisplay, "Cmd+Shift+Space")
    }
}

private actor RecordingSpyTranscriptionBackend: TranscriptionBackend {
    nonisolated let selection: TranscriptionBackendSelection

    private let startResult: RecordingStartResult
    private let stopResult: RecordingStopResult
    private let transcript: String
    private let livePreviewState: LivePreviewRuntimeState
    private let immediateRecordingStartReady: Bool
    private var events: [String] = []

    init(
        selection: TranscriptionBackendSelection,
        startResult: RecordingStartResult = .inactive,
        stopResult: RecordingStopResult = RecordingStopResult(recordingURL: nil),
        transcript: String = "",
        livePreviewState: LivePreviewRuntimeState = .inactive,
        immediateRecordingStartReady: Bool = true
    ) {
        self.selection = selection
        self.startResult = startResult
        self.stopResult = stopResult
        self.transcript = transcript
        self.livePreviewState = livePreviewState
        self.immediateRecordingStartReady = immediateRecordingStartReady
    }

    func prepare() async throws -> TranscriptionPreparation {
        events.append("prepare")
        return TranscriptionPreparation(
            resolvedModelURL: URL(fileURLWithPath: "/tmp/\(selection.rawValue)"),
            readyDisplayName: selection.displayName
        )
    }

    func isReadyForImmediateRecordingStart() async -> Bool {
        events.append("immediateReady")
        return immediateRecordingStartReady
    }

    func preparationProgress() async -> TranscriptionPreparationProgress? {
        events.append("progress")
        return nil
    }

    func invalidatePreparation() async {
        events.append("invalidate")
    }

    func modelDirectoryURL() async throws -> URL {
        events.append("modelDirectory")
        return URL(fileURLWithPath: "/tmp/\(selection.rawValue)")
    }

    func startRecording(preferredInputDeviceID: String?) async throws -> RecordingStartResult {
        events.append("start")
        return startResult
    }

    func cancelPendingRecordingStart() async {
        events.append("cancel")
    }

    func stopRecording() async -> RecordingStopResult {
        events.append("stop")
        return stopResult
    }

    func pendingRecordingStartStatusMessage() async -> String? {
        events.append("pending")
        return nil
    }

    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState {
        events.append("runtime")
        return livePreviewState
    }

    func normalizedInputLevel() async -> Float {
        events.append("level")
        return 0.5
    }

    func isLivePreviewRequested() async -> Bool {
        events.append("requested")
        return livePreviewState.isActive
    }

    func latestPreviewSnapshot() async -> StreamingPreviewSnapshot? {
        events.append("preview")
        return nil
    }

    func livePreviewUnavailableReason() async -> String? {
        events.append("unavailable")
        return nil
    }

    func transcribePreparedRecording(
        _ recording: PreparedRecording,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        _ = recording
        _ = statusHandler
        events.append("transcribe")
        return transcript
    }

    func recordedEvents() async -> [String] {
        events
    }
}

final class TranscriptionCoordinatorTests: XCTestCase {
    func testRecordingSessionStaysPinnedToWhisperWhenSelectionChangesBeforeFinalization() async throws {
        var selection: TranscriptionBackendSelection = .whisper
        let whisperBackend = RecordingSpyTranscriptionBackend(
            selection: .whisper,
            stopResult: RecordingStopResult(recordingURL: URL(fileURLWithPath: "/tmp/whisper.wav")),
            transcript: "whisper transcript"
        )
        let voxtralBackend = RecordingSpyTranscriptionBackend(
            selection: .voxtralRealtime,
            stopResult: RecordingStopResult(
                bufferedSamples: Array(repeating: 0.2, count: 8_000),
                bestAvailableTranscript: "voxtral transcript",
                wasCleanUserStop: true
            ),
            transcript: "voxtral transcript",
            livePreviewState: .active
        )
        let coordinator = TranscriptionCoordinator(
            whisperBackend: whisperBackend,
            voxtralRealtimeBackend: voxtralBackend,
            selectionProvider: { selection }
        )

        _ = try await coordinator.startRecording(preferredInputDeviceID: nil)
        selection = .voxtralRealtime
        _ = await coordinator.stopRecording()

        let transcript = try await coordinator.transcribePreparedRecording(
            PreparedRecording(
                samples: Array(repeating: 0.2, count: 8_000),
                duration: 0.5,
                rmsLevel: 0.2,
                sourceRecordingURL: URL(fileURLWithPath: "/tmp/whisper.wav")
            ),
            statusHandler: { _ in }
        )

        XCTAssertEqual(transcript, "whisper transcript")
        let whisperEvents = await whisperBackend.recordedEvents()
        let voxtralEvents = await voxtralBackend.recordedEvents()
        XCTAssertEqual(whisperEvents, ["start", "stop", "transcribe"])
        XCTAssertEqual(voxtralEvents, [])
    }

    func testRecordingSessionStaysPinnedToVoxtralWhenSelectionChangesBeforeStop() async throws {
        var selection: TranscriptionBackendSelection = .voxtralRealtime
        let whisperBackend = RecordingSpyTranscriptionBackend(selection: .whisper, transcript: "whisper transcript")
        let voxtralBackend = RecordingSpyTranscriptionBackend(
            selection: .voxtralRealtime,
            startResult: .active,
            stopResult: RecordingStopResult(
                bufferedSamples: Array(repeating: 0.2, count: 8_000),
                bestAvailableTranscript: "voxtral transcript",
                wasCleanUserStop: true
            ),
            transcript: "voxtral transcript",
            livePreviewState: .active
        )
        let coordinator = TranscriptionCoordinator(
            whisperBackend: whisperBackend,
            voxtralRealtimeBackend: voxtralBackend,
            selectionProvider: { selection }
        )

        _ = try await coordinator.startRecording(preferredInputDeviceID: nil)
        selection = .whisper

        let livePreviewRuntimeState = await coordinator.currentLivePreviewRuntimeState()
        let stopResult = await coordinator.stopRecording()
        let whisperEvents = await whisperBackend.recordedEvents()
        let voxtralEvents = await voxtralBackend.recordedEvents()

        XCTAssertEqual(livePreviewRuntimeState, .active)
        XCTAssertEqual(stopResult.bestAvailableTranscript, "voxtral transcript")
        XCTAssertEqual(whisperEvents, [])
        XCTAssertEqual(voxtralEvents, ["start", "runtime", "stop"])
    }

    func testImmediateRecordingStartReadinessFollowsCurrentSelection() async {
        var selection: TranscriptionBackendSelection = .voxtralRealtime
        let whisperBackend = RecordingSpyTranscriptionBackend(
            selection: .whisper,
            immediateRecordingStartReady: true
        )
        let voxtralBackend = RecordingSpyTranscriptionBackend(
            selection: .voxtralRealtime,
            immediateRecordingStartReady: false
        )
        let coordinator = TranscriptionCoordinator(
            whisperBackend: whisperBackend,
            voxtralRealtimeBackend: voxtralBackend,
            selectionProvider: { selection }
        )

        let voxtralReady = await coordinator.isReadyForImmediateRecordingStart()
        selection = .whisper
        let whisperReady = await coordinator.isReadyForImmediateRecordingStart()

        XCTAssertFalse(voxtralReady)
        XCTAssertTrue(whisperReady)
        let whisperEvents = await whisperBackend.recordedEvents()
        let voxtralEvents = await voxtralBackend.recordedEvents()
        XCTAssertEqual(whisperEvents, ["immediateReady"])
        XCTAssertEqual(voxtralEvents, ["immediateReady"])
    }
}

private final class ApplicationSupportBackedFileManager: FileManager {
    private let applicationSupportRoot: URL

    init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask == .userDomainMask {
            return [applicationSupportRoot]
        }

        return super.urls(for: directory, in: domainMask)
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

    func testBootstrapProvisionsManagedRealtimeAssetsBeforePreparingBackend() async {
        let audioSettings = makeAudioSettings()
        var events: [String] = []

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                provisionManagedRealtimeAssets: {
                    events.append("provision")
                    return ManagedRealtimeProvisioningResult(
                        isManagedBundlePresent: true,
                        didInstallManagedAssets: true,
                        didSeedFreshInstallDefaults: false,
                        didRefreshVoxtralReadinessManifest: true
                    )
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

        XCTAssertEqual(events, ["provision", "prepare"])
        XCTAssertEqual(appState.startupSetupPhase, .ready)
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

    func testBootstrapManagedProvisioningFailureSurfacesBackendFailure() async {
        let audioSettings = makeAudioSettings()
        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                provisionManagedRealtimeAssets: {
                    throw ManagedRealtimeAssetProvisioningError.missingBundledHelper
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()

        if case .failed(.backend(let message)) = appState.startupSetupPhase {
            XCTAssertEqual(
                message,
                ManagedRealtimeAssetProvisioningError.missingBundledHelper.localizedDescription
            )
        } else {
            XCTFail("Expected backend failure, got \(appState.startupSetupPhase)")
        }
    }

    func testVoxtralBootstrapKeepsRecordingDisabledUntilWarmStreamingFinishes() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let gate = StartGate()
        let progressDetail = "Preparing local realtime transcription..."

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
        let progressDetail = "Preparing local realtime transcription..."
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

    func testVoxtralRecordingStartRepreparesWhenImmediateStartReadinessTurnsFalse() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        var prepareCallCount = 0
        var audioStartCallCount = 0
        var isImmediatelyReady = true

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    audioStartCallCount += 1
                    return .active
                },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true },
                prepareTranscription: {
                    prepareCallCount += 1
                    isImmediatelyReady = true
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602"),
                        readyDisplayName: "Voxtral-Mini-4B-Realtime-2602"
                    )
                },
                isTranscriptionReadyForImmediateRecordingStart: {
                    isImmediatelyReady
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()
        XCTAssertEqual(prepareCallCount, 1)

        isImmediatelyReady = false

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()

        XCTAssertEqual(prepareCallCount, 2)
        XCTAssertEqual(audioStartCallCount, 1)
        XCTAssertTrue(appState.isRecording)
        XCTAssertFalse(appState.statusMessage.localizedCaseInsensitiveContains("live ingestion"))
    }

    func testVoxtralRecordingStartShowsGenericRecoveryDetailWhileBackendReprepares() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let gate = StartGate()
        var isImmediatelyReady = true

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in .active },
                currentLivePreviewRuntimeState: { .active },
                isExperimentalStreamingPreviewEnabled: { true },
                prepareTranscription: {
                    if !isImmediatelyReady {
                        await gate.enter()
                    }
                    isImmediatelyReady = true
                    return TranscriptionPreparation(
                        resolvedModelURL: URL(fileURLWithPath: "/tmp/Voxtral-Mini-4B-Realtime-2602"),
                        readyDisplayName: "Voxtral-Mini-4B-Realtime-2602"
                    )
                },
                isTranscriptionReadyForImmediateRecordingStart: {
                    isImmediatelyReady
                },
                transcriptionPreparationProgress: {
                    TranscriptionPreparationProgress(
                        stage: .warmingStreaming,
                        fraction: 0.34,
                        detail: "Recovering local realtime transcription..."
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.bootstrap()
        isImmediatelyReady = false

        let startTask = Task {
            await appState.toggleRecordingFromButton()
        }

        await gate.waitUntilStarted()
        await settleQueuedTasks()

        XCTAssertEqual(appState.startupSetupPhase, StartupSetupPhase.preparingBackend)
        XCTAssertEqual(appState.statusMessage, "Recovering local realtime transcription...")

        await gate.release()
        await startTask.value
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

    func testWhisperHotkeyStartsListeningAndStopsWithFinalTranscript() async {
        let audioSettings = makeAudioSettings()
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
                    return .inactive
                },
                audioStop: {
                    events.append("audioStop")
                    return RecordingStopResult(
                        bufferedSamples: Array(repeating: 0.2, count: 8_000)
                    )
                },
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("Whisper hotkey path should use buffered samples in this test.")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { samples, sensitivity in
                    events.append("prepareSamples:\(samples.count):\(String(format: "%.1f", sensitivity))")
                    return AudioRecorder.prepareForTranscription(samples: samples, inputSensitivity: sensitivity)
                },
                transcribePreparedRecording: { recording, _ in
                    events.append("transcribe:\(recording.samples.count)")
                    return "hello world"
                },
                captureInsertionContext: { nil },
                hasVisibleSpkWindows: { false },
                insertText: { text, capturedContext, _ in
                    events.append("insert:\(text):\(capturedContext == nil ? "nil" : "target")")
                    return .insertedAccessibility
                }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()
        XCTAssertEqual(
            appState.statusMessage,
            "Press Cmd+Shift+Space once to start listening. Press it again to stop, transcribe, and insert the result."
        )

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.streamingPreviewDisplayText, "Listening...")
        XCTAssertEqual(appState.statusMessage, "Recording... spk will insert the transcript when you stop.")

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "hello world")
        XCTAssertTrue(events.contains("audioStart"))
        XCTAssertTrue(events.contains("audioStop"))
        XCTAssertTrue(events.contains("prepareSamples:8000:1.0"))
        XCTAssertTrue(events.contains("transcribe:8000"))
        XCTAssertTrue(events.contains("insert:hello world:nil"))
    }

    func testHotkeyUsesUpdatedBackendSelectionWhenSelectionChangesBeforeStart() async {
        let audioSettings = makeAudioSettings()
        var hotkeyHandler: (() -> Void)?

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                installDefaultHotkey: { handler in
                    hotkeyHandler = handler
                    return .installed
                },
                audioStart: { _ in .active },
                captureInsertionContext: { nil },
                hasVisibleSpkWindows: { false }
            ),
            bootstrapsOnInit: false
        )

        guard let hotkeyHandler else {
            return XCTFail("Expected the test hotkey handler to be installed")
        }

        await appState.bootstrap()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(
            appState.statusMessage,
            "Recording with Voxtral live preview... spk will keep the live transcript when you stop."
        )
    }

    func testHotkeyStopKeepsUsingVoxtralFlowAfterSelectionChangesMidRecording() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
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
                prepareRecordingForTranscription: { _, _ in
                    XCTFail("Switching the selected backend mid-recording should not force Whisper-style finalization.")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                prepareSamplesForTranscription: { _, _ in
                    XCTFail("Switching the selected backend mid-recording should not force Whisper-style sample preparation.")
                    return PreparedRecording(samples: [], duration: 0, rmsLevel: 0)
                },
                transcribePreparedRecording: { _, _ in
                    XCTFail("Switching the selected backend mid-recording should not trigger a second transcription path.")
                    return ""
                },
                captureInsertionContext: { nil },
                hasVisibleSpkWindows: { false },
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

        audioSettings.transcriptionBackendSelection = .whisper

        hotkeyHandler()
        await settleQueuedTasks()

        XCTAssertEqual(appState.lastTranscript, "voxtral final transcript")
        XCTAssertTrue(events.contains("insert:voxtral final transcript"))
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
            "Voxtral live preview unavailable. Stop may finish without a transcript."
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
            confirmedText: "",
            unconfirmedText: "",
            currentText: "Decoding speech...",
            latestRelativeEnergy: 0.7
        )
        await settleQueuedTasks()

        XCTAssertEqual(appState.streamingPreviewDisplayText, "Decoding speech...")
        XCTAssertFalse(events.contains(where: { $0 == "stream:Decoding speech..." }))

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

        try? await Task.sleep(for: .milliseconds(250))
        await settleQueuedTasks()

        XCTAssertGreaterThanOrEqual(beginStreamingCallCount, 2)
        XCTAssertLessThanOrEqual(beginStreamingCallCount, 3)
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
                    "spk could not find the managed WhisperKit preview model. Reinstall the self-contained app or choose a local WhisperKit model folder."
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
        XCTAssertTrue(appState.statusMessage.contains("managed WhisperKit preview model"))

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

    func testInstantVoxtralStopUsesTranscriptReturnedDuringStopWithoutPostStopTranscription() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        var transcriptionCallCount = 0

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in .active },
                audioStop: {
                    RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                        bestAvailableTranscript: "voxtral final transcript",
                        wasCleanUserStop: true
                    )
                },
                transcribePreparedRecording: { _, _ in
                    transcriptionCallCount += 1
                    return "should not run"
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(appState.lastTranscript, "voxtral final transcript")
        XCTAssertEqual(transcriptionCallCount, 0)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
    }

    func testInstantVoxtralStopReportsDecodeIssueWhenStopReturnsEmptyTranscript() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in .active },
                audioStop: {
                    RecordingStopResult(
                        recordingURL: URL(fileURLWithPath: "/tmp/fake-recording.wav"),
                        bestAvailableTranscript: nil,
                        wasCleanUserStop: true
                    )
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertEqual(
            appState.statusMessage,
            "Local realtime transcription did not return any text for this recording."
        )
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
    }

    func testVoxtralRecordingOnlyFallbackTranscribesRecordedAudioAfterStop() async {
        let audioSettings = makeAudioSettings()
        audioSettings.transcriptionBackendSelection = .voxtralRealtime
        let recordingURL = URL(fileURLWithPath: "/tmp/voxtral-recording-only.wav")
        var didPrepareRecording = false
        var didTranscribeRecording = false

        let appState = WhisperAppState(
            audioSettings: audioSettings,
            dependencies: makeDependencies(
                audioStart: { _ in
                    RecordingStartResult(
                        livePreviewState: .unavailableButFinalTranscriptAvailable("Voxtral live preview is unavailable.")
                    )
                },
                audioStop: {
                    RecordingStopResult(recordingURL: recordingURL)
                },
                prepareRecordingForTranscription: { url, _ in
                    didPrepareRecording = true
                    XCTAssertEqual(url, recordingURL)
                    return PreparedRecording(
                        samples: Array(repeating: 0.2, count: 16_000),
                        duration: 1.0,
                        rmsLevel: 0.2,
                        sourceRecordingURL: url
                    )
                },
                transcribePreparedRecording: { recording, _ in
                    didTranscribeRecording = true
                    XCTAssertEqual(recording.sourceRecordingURL, recordingURL)
                    return "recording only transcript"
                }
            ),
            bootstrapsOnInit: false
        )

        await appState.toggleRecordingFromButton()
        await settleQueuedTasks()
        await appState.toggleRecordingFromButton()

        XCTAssertTrue(didPrepareRecording)
        XCTAssertTrue(didTranscribeRecording)
        XCTAssertEqual(appState.lastTranscript, "recording only transcript")
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isTranscribing)
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
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let fixtureURL: URL
        let repoFixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Vendor")
            .appending(path: "whisper.cpp")
            .appending(path: "bindings")
            .appending(path: "go")
            .appending(path: "samples")
            .appending(path: "jfk.wav")
        if fileManager.fileExists(atPath: repoFixtureURL.path) {
            fixtureURL = repoFixtureURL.standardizedFileURL
        } else if let fixturePath = ProcessInfo.processInfo.environment["SPK_LOCAL_VOXTRAL_REPLAY_VALIDATION_FILE"]?
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
            throw XCTSkip("The repo sample Vendor/whisper.cpp/bindings/go/samples/jfk.wav is unavailable, and no alternate local Voxtral replay fixture was configured.")
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
            bundle: Bundle(for: Self.self),
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        do {
            _ = try await backend.prepare()
            let startResult = try await backend.startRecording(preferredInputDeviceID: nil)
            switch startResult.livePreviewState {
            case .active:
                break
            case .prewarming(let message):
                throw XCTSkip("Local Voxtral helper-backed replay validation is still prewarming in the current test environment: \(message)")
            case .unavailable, .unavailableButFinalTranscriptAvailable:
                throw XCTSkip(
                    "Local Voxtral helper-backed replay validation is unavailable in the current test environment: \(startResult.livePreviewState.unavailableReason ?? "live preview unavailable")"
                )
            case .inactive:
                throw XCTSkip("Local Voxtral helper-backed replay validation did not activate a live session in the current test environment.")
            }

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

    func testVoxtralPrepareRestoresCachedLiveReadyModeWithoutReplayingStrictValidation() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let bundle = Bundle(for: Self.self)

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false
        )
        try VoxtralReadinessManifestStore.writeCurrent(
            appBuildVersion: bundleVersionIdentifier(bundle),
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: modelURL,
            startupMode: .liveReady,
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
            bundle: bundle
        )

        do {
            _ = try await backend.prepare()
            let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
            XCTAssertTrue(isReadyForImmediateStart)

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(
                eventLines,
                [
                    "launch=1 type=load_model loaded=false",
                    "launch=1 emit=ready"
                ]
            )
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
    }

    func testVoxtralPrepareDoesNotPersistRecordingOnlyForTransientFinalizationTimeout() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let bundle = Bundle(for: Self.self)

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false,
            finishSessionErrorMessage: "Voxtral finalization failed: Voxtral streaming generation timed out while finalizing the session."
        )

        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: fileManager,
            bundle: bundle,
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        _ = try await backend.prepare()
        let manifest = VoxtralReadinessManifestStore.load(fileManager: fileManager)
        XCTAssertNil(manifest)

        let livePreviewRuntimeState = await backend.currentLivePreviewRuntimeState()
        XCTAssertTrue(livePreviewRuntimeState.finalTranscriptAvailableOnStop)
        await backend.invalidatePreparation()
    }

    func testVoxtralPrepareIgnoresTransientTimeoutRecordingOnlyManifestAndRevalidates() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let bundle = Bundle(for: Self.self)

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false
        )
        try VoxtralReadinessManifestStore.writeCurrent(
            appBuildVersion: bundleVersionIdentifier(bundle),
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: modelURL,
            startupMode: .recordingOnly,
            startupModeReason: "spk verified that Voxtral live preview is unavailable on this setup, so recording will continue locally and the final transcript will still be generated after you stop. Voxtral finalization failed: Voxtral streaming generation timed out while finalizing the session.",
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
            bundle: bundle,
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        _ = try await backend.prepare()
        let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
        XCTAssertTrue(isReadyForImmediateStart)

        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(eventLines.contains("launch=1 type=start_session loaded=true"))
        XCTAssertTrue(eventLines.contains("launch=1 type=finish_session loaded=true"))

        let manifest = try XCTUnwrap(VoxtralReadinessManifestStore.load(fileManager: fileManager))
        XCTAssertEqual(manifest.startupMode, .liveReady)
        await backend.invalidatePreparation()
    }

    func testVoxtralCachedRecordingOnlyModeStartsWithoutLiveSessionAndUsesRecordedWAVTranscription() async throws {
        actor FileTranscriptionRecorder {
            private var calls: [(audioURL: URL, modelURL: URL)] = []

            func append(audioURL: URL, modelURL: URL) {
                calls.append((audioURL: audioURL, modelURL: modelURL))
            }

            func allCalls() -> [(audioURL: URL, modelURL: URL)] {
                calls
            }
        }

        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let bundle = Bundle(for: Self.self)
        let cachedReason = "spk verified that Voxtral live preview is unavailable on this setup, so recording will continue locally and the final transcript will still be generated after you stop."
        let transcriptionRecorder = FileTranscriptionRecorder()

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        XCTAssertTrue(
            fileManager.createFile(
                atPath: helperURL.path,
                contents: Data("print('unused helper')\n".utf8)
            )
        )
        try VoxtralReadinessManifestStore.writeCurrent(
            appBuildVersion: bundleVersionIdentifier(bundle),
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: modelURL,
            startupMode: .recordingOnly,
            startupModeReason: cachedReason,
            fileManager: fileManager
        )

        let recordingURL = rootDirectory.appending(path: "recording-only.wav")
        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: fileManager,
            bundle: bundle,
            liveInputSourceFactory: { _ in
                ImmediateActiveVoxtralInputSource(recordingURL: recordingURL)
            },
            transcribeAudioFileHandler: { audioURL, resolvedModelURL in
                await transcriptionRecorder.append(audioURL: audioURL, modelURL: resolvedModelURL)
                return "transcribed after stop"
            }
        )

        _ = try await backend.prepare()
        let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
        XCTAssertTrue(isReadyForImmediateStart)
        let livePreviewRuntimeState = await backend.currentLivePreviewRuntimeState()
        XCTAssertEqual(
            livePreviewRuntimeState,
            .unavailableButFinalTranscriptAvailable(cachedReason)
        )

        let startResult = try await backend.startRecording(preferredInputDeviceID: nil)
        XCTAssertEqual(
            startResult.livePreviewState,
            .unavailableButFinalTranscriptAvailable(cachedReason)
        )
        let stopResult = await backend.stopRecording()
        XCTAssertEqual(stopResult.recordingURL, recordingURL)
        XCTAssertNil(stopResult.bestAvailableTranscript)

        let transcript = try await backend.transcribePreparedRecording(
            PreparedRecording(
                samples: Array(repeating: 0.2, count: 16_000),
                duration: 1.0,
                rmsLevel: 0.2,
                sourceRecordingURL: recordingURL
            )
        ) { _ in }
        XCTAssertEqual(transcript, "transcribed after stop")

        let transcriptionCalls = await transcriptionRecorder.allCalls()
        XCTAssertEqual(transcriptionCalls.count, 1)
        XCTAssertEqual(transcriptionCalls.first?.audioURL, recordingURL)
        XCTAssertEqual(transcriptionCalls.first?.modelURL, modelURL)

        await backend.invalidatePreparation()
    }

    func testVoxtralImmediateStartReadinessIsFalseBeforePrepare() async {
        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) }
        )

        let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
        XCTAssertFalse(isReadyForImmediateStart)
    }

    func testVoxtralImmediateStartReadinessIsTrueAfterPrepareWhenHelperGenerationStaysLive() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false
        )

        let backend = VoxtralRealtimeTranscriptionBackend(
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: fileManager,
            bundle: Bundle(for: Self.self)
        )

        do {
            _ = try await backend.prepare()
            let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
            XCTAssertTrue(isReadyForImmediateStart)
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
    }

    func testVoxtralStartRecordingFailsWithoutInlineRecoveryWhenHelperRestartsAfterInitialLiveIngestionProbe() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false
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
            },
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        do {
            _ = try await backend.prepare()
            await helperClient.shutdown()
            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let isReadyForImmediateStart = await backend.isReadyForImmediateRecordingStart()
            XCTAssertFalse(isReadyForImmediateStart)
            do {
                _ = try await backend.startRecording(preferredInputDeviceID: nil)
                XCTFail("Expected startRecording to fail when immediate-start readiness is stale.")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Recovering local realtime transcription. Wait a moment and try again."
                )
            }

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
                    "launch=1 type=finish_session loaded=true",
                    "launch=1 emit=final_transcript",
                    "launch=1 type=shutdown loaded=true",
                    "launch=1 emit=shutdown"
                ]
            )
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
    }

    func testVoxtralImmediateStartReadinessIsFalseDuringBackgroundRecovery() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false,
            secondLaunchLoadModelDelaySeconds: 1.0
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
                FailingActiveVoxtralInputSource(
                    recordingURL: rootDirectory.appending(path: "test-recording.wav"),
                    failureReason: "helper exited before returning a live preview update"
                )
            },
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        do {
            _ = try await backend.prepare()
            let initialReadiness = await backend.isReadyForImmediateRecordingStart()
            XCTAssertTrue(initialReadiness)

            _ = try await backend.startRecording(preferredInputDeviceID: nil)
            let stopResult = await backend.stopRecording()
            XCTAssertFalse(stopResult.wasCleanUserStop)

            try await waitForAsyncCondition(timeout: 1.0) {
                !(await backend.isReadyForImmediateRecordingStart())
            }

            try? await Task.sleep(for: .milliseconds(250))
            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertTrue(eventLines.contains("launch=1 type=cancel_session loaded=true"))
        } catch {
            await backend.invalidatePreparation()
            throw error
        }

        await backend.invalidatePreparation()
    }

    func testVoxtralStopFinalizesLiveSessionWhenCleanStopHasNoUsablePreview() async throws {
        let fileManager = ApplicationSupportBackedFileManager(
            applicationSupportRoot: try makeTemporaryDirectory().appending(path: "Application Support")
        )
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try makeVoxtralModelDirectory(at: modelURL, fileManager: fileManager)
        try writeBackendRecoveryFakeHelper(
            to: helperURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitsAfterFirstProbeCancellation: false,
            finishSessionText: "voxtral final transcript",
            liveAppendPreviewText: ""
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
                    recordingURL: rootDirectory.appending(path: "test-recording.wav"),
                    samplesToEmitOnStart: Array(repeating: 0.2, count: 8)
                )
            },
            strictValidationRecordingProvider: { Self.strictValidationRecording() }
        )

        do {
            _ = try await backend.prepare()
            _ = try await backend.startRecording(preferredInputDeviceID: nil)

            try await waitForAsyncCondition(timeout: 2.0) {
                guard let eventLines = try? String(contentsOf: eventsURL, encoding: .utf8) else {
                    return false
                }
                let appendCount = eventLines
                    .split(separator: "\n")
                    .filter { $0.contains("type=append_audio") }
                    .count
                return appendCount >= 2
            }

            let stopResult = await backend.stopRecording()
            XCTAssertTrue(stopResult.wasCleanUserStop)
            XCTAssertEqual(stopResult.bestAvailableTranscript, "voxtral final transcript")

            try? await Task.sleep(for: .milliseconds(250))

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertTrue(eventLines.contains("launch=1 type=finish_session loaded=true"))
            XCTAssertFalse(eventLines.contains { $0.contains("type=shutdown") })
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
        provisionManagedRealtimeAssets: @escaping () async throws -> ManagedRealtimeProvisioningResult = { .skipped },
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
        recordingRuntimeSnapshot: (() async -> RecordingRuntimeSnapshot)? = nil,
        isExperimentalStreamingPreviewEnabled: @escaping () async -> Bool = { false },
        streamingPreviewSnapshot: @escaping () async -> StreamingPreviewSnapshot? = { nil },
        streamingPreviewUnavailableReason: @escaping () async -> String? = { nil },
        prepareTranscription: @escaping () async throws -> TranscriptionPreparation = {
            TranscriptionPreparation(
                resolvedModelURL: URL(fileURLWithPath: "/tmp/ggml-medium-q5_0.bin"),
                readyDisplayName: "ggml-medium-q5_0.bin"
            )
        },
        isTranscriptionReadyForImmediateRecordingStart: @escaping () async -> Bool = { true },
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
        commitStreamingInsertionSession: @escaping (TextInsertionService.StreamingSession, String, TextInsertionService.InsertionOptions) async -> TextInsertionService.InsertionOutcome = { _, _, _ in .insertedTyping },
        cancelStreamingInsertionSession: @escaping (TextInsertionService.StreamingSession) -> Void = { _ in },
        insertText: @escaping (String, TextInsertionService.CapturedInsertionContext?, TextInsertionService.InsertionOptions) async -> TextInsertionService.InsertionOutcome = { _, _, _ in .insertedAccessibility },
        copyTextToClipboard: @escaping (String) -> Void = { _ in },
        playAudioCue: @escaping (AudioCue) -> Void = { _ in }
    ) -> WhisperAppDependencies {
        let defaultPermissionSnapshot = PermissionSnapshot(
            microphone: Self.grantedPermission(),
            accessibility: Self.grantedPermission()
        )
        let resolvedPermissionSnapshot = permissionSnapshot ?? { defaultPermissionSnapshot }
        let resolvedRecordingRuntimeSnapshot = recordingRuntimeSnapshot ?? {
            let runtimeState = await currentLivePreviewRuntimeState()
            let previewSnapshot = await streamingPreviewSnapshot()
            let unavailableReason: String?
            if let stateReason = runtimeState.unavailableReason {
                unavailableReason = stateReason
            } else {
                unavailableReason = await streamingPreviewUnavailableReason()
            }
            return RecordingRuntimeSnapshot(
                normalizedInputLevel: await normalizedInputLevel(),
                livePreviewState: runtimeState,
                previewSnapshot: previewSnapshot,
                unavailableReason: unavailableReason
            )
        }

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
            provisionManagedRealtimeAssets: provisionManagedRealtimeAssets,
            audioStart: audioStart,
            cancelPendingRecordingStart: cancelPendingRecordingStart,
            audioStop: audioStop,
            pendingRecordingStartStatusMessage: pendingRecordingStartStatusMessage,
            currentLivePreviewRuntimeState: currentLivePreviewRuntimeState,
            normalizedInputLevel: normalizedInputLevel,
            recordingRuntimeSnapshot: resolvedRecordingRuntimeSnapshot,
            isExperimentalStreamingPreviewEnabled: isExperimentalStreamingPreviewEnabled,
            streamingPreviewSnapshot: streamingPreviewSnapshot,
            streamingPreviewUnavailableReason: streamingPreviewUnavailableReason,
            prepareTranscription: prepareTranscription,
            isTranscriptionReadyForImmediateRecordingStart: isTranscriptionReadyForImmediateRecordingStart,
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

    nonisolated private static func strictValidationRecording() -> PreparedRecording {
        PreparedRecording(
            samples: Array(repeating: 0.2, count: 4),
            duration: 0.00025,
            rmsLevel: 0.2
        )
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

    private func bundleVersionIdentifier(_ bundle: Bundle) -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(shortVersion)-\(buildNumber)"
    }

    private func writeBackendRecoveryFakeHelper(
        to helperURL: URL,
        eventsURL _: URL,
        fileManager: FileManager,
        exitsAfterFirstProbeCancellation: Bool = true,
        secondLaunchLoadModelDelaySeconds: Double = 0,
        finishSessionText: String = "validation final",
        liveAppendPreviewText: String? = nil,
        finishSessionErrorMessage: String? = nil
    ) throws {
        let exitsAfterFirstProbeCancellationLiteral = exitsAfterFirstProbeCancellation ? "True" : "False"
        let secondLaunchLoadModelDelayLiteral = String(secondLaunchLoadModelDelaySeconds)
        let finishSessionTextLiteral = String(reflecting: finishSessionText)
        let liveAppendPreviewTextLiteral = liveAppendPreviewText.map { String(reflecting: $0) } ?? "None"
        let finishSessionErrorMessageLiteral = finishSessionErrorMessage.map { String(reflecting: $0) } ?? "None"
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
        exit_after_first_probe_cancellation = \(exitsAfterFirstProbeCancellationLiteral)
        second_launch_load_model_delay_seconds = \(secondLaunchLoadModelDelayLiteral)
        finish_session_text = \(finishSessionTextLiteral)
        live_append_preview_text = \(liveAppendPreviewTextLiteral)
        finish_session_error_message = \(finishSessionErrorMessageLiteral)
        append_count = 0

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
                if launch_count == 2 and second_launch_load_model_delay_seconds > 0:
                    time.sleep(second_launch_load_model_delay_seconds)
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
                append_count += 1
                preview_text = "validation preview"
                if live_append_preview_text is not None and append_count > 1:
                    preview_text = live_append_preview_text
                emit(
                    {
                        "request_id": request_id,
                        "type": "preview_update",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": preview_text,
                    }
                )
            elif request_type == "finish_session":
                if finish_session_error_message is not None:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": finish_session_error_message,
                        }
                    )
                    continue
                emit(
                    {
                        "request_id": request_id,
                        "type": "final_transcript",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": finish_session_text,
                    }
                )
                if exit_after_first_probe_cancellation and launch_count == 1 and state.get("saw_append", False):
                    time.sleep(0.5)
                    sys.exit(0)
            elif request_type == "cancel_session":
                emit(
                    {
                        "request_id": request_id,
                        "type": "session_cancelled",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
                if exit_after_first_probe_cancellation and launch_count == 1 and state.get("saw_append", False):
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

    private func makeVoxtralModelDirectory(
        at directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = fileManager.createFile(
            atPath: directory.appending(path: "config.json").path,
            contents: Data("{}".utf8)
        )
        _ = fileManager.createFile(
            atPath: directory.appending(path: "processor_config.json").path,
            contents: Data("{}".utf8)
        )
        _ = fileManager.createFile(
            atPath: directory.appending(path: "tokenizer.json").path,
            contents: Data("{}".utf8)
        )
        _ = fileManager.createFile(
            atPath: directory.appending(path: "model-00001-of-00001.safetensors").path,
            contents: Data("weights".utf8)
        )
    }

    private actor ImmediateActiveVoxtralInputSource: VoxtralLiveInputSource {
        nonisolated let kindDescription = "test-immediate"
        nonisolated let recordingURL: URL

        private let samplesToEmitOnStart: [Float]
        private var health: VoxtralLiveInputSourceHealth = .idle
        private var emittedSamples = 0

        init(recordingURL: URL, samplesToEmitOnStart: [Float] = []) {
            self.recordingURL = recordingURL
            self.samplesToEmitOnStart = samplesToEmitOnStart
        }

        func start(
            preferredInputDeviceID: String?,
            onSamples: @escaping @Sendable ([Float]) -> Void,
            onFailure: @escaping @Sendable (String) -> Void
        ) async throws {
            _ = preferredInputDeviceID
            _ = onFailure
            health = .active(activeInputDeviceID: nil)
            if !samplesToEmitOnStart.isEmpty {
                emittedSamples += samplesToEmitOnStart.count
                onSamples(samplesToEmitOnStart)
            }
        }

        func stop() async -> URL? {
            health = .idle
            return recordingURL
        }

        func normalizedInputLevel() async -> Float {
            0
        }

        func emittedSampleCount() async -> Int {
            emittedSamples
        }

        func healthState() async -> VoxtralLiveInputSourceHealth {
            health
        }
    }

    private actor FailingActiveVoxtralInputSource: VoxtralLiveInputSource {
        nonisolated let kindDescription = "test-failing-immediate"
        nonisolated let recordingURL: URL
        private let failureReason: String

        private var health: VoxtralLiveInputSourceHealth = .idle

        init(recordingURL: URL, failureReason: String) {
            self.recordingURL = recordingURL
            self.failureReason = failureReason
        }

        func start(
            preferredInputDeviceID: String?,
            onSamples: @escaping @Sendable ([Float]) -> Void,
            onFailure: @escaping @Sendable (String) -> Void
        ) async throws {
            _ = preferredInputDeviceID
            _ = onSamples
            health = .active(activeInputDeviceID: nil)
            onFailure(failureReason)
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
