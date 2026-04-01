import Foundation

actor WhisperTranscriptionBackend: TranscriptionBackend {
    let selection: TranscriptionBackendSelection = .whisper

    private let whisperBridge: WhisperBridge
    private let streamingCoordinator: WhisperKitStreamingCoordinator
    private let audioRecorder: AudioRecorder
    private let settingsSnapshotProvider: @Sendable () async -> WhisperKitStreamingSettingsSnapshot
    private let environment: [String: String]
    private var livePreviewRuntimeState: LivePreviewRuntimeState = .inactive

    init(
        whisperBridge: WhisperBridge = WhisperBridge(),
        streamingCoordinator: WhisperKitStreamingCoordinator,
        audioRecorder: AudioRecorder,
        settingsSnapshotProvider: @escaping @Sendable () async -> WhisperKitStreamingSettingsSnapshot,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.whisperBridge = whisperBridge
        self.streamingCoordinator = streamingCoordinator
        self.audioRecorder = audioRecorder
        self.settingsSnapshotProvider = settingsSnapshotProvider
        self.environment = environment
    }

    func prepare() async throws -> TranscriptionPreparation {
        let modelURL = try await whisperBridge.prepareModel()
        await streamingCoordinator.prepareForStartup()
        return TranscriptionPreparation(
            resolvedModelURL: modelURL,
            readyDisplayName: modelURL.lastPathComponent
        )
    }

    func preparationProgress() async -> TranscriptionPreparationProgress? {
        nil
    }

    func invalidatePreparation() async {}

    func modelDirectoryURL() async throws -> URL {
        try await whisperBridge.modelDirectoryURL()
    }

    func startRecording(preferredInputDeviceID: String?) async throws -> RecordingStartResult {
        let livePreviewStarted = try await audioRecorder.start(preferredInputDeviceID: preferredInputDeviceID)
        livePreviewRuntimeState = livePreviewStarted ? .active : .inactive
        return livePreviewStarted ? .active : .inactive
    }

    func stopRecording() async -> RecordingStopResult {
        livePreviewRuntimeState = .inactive
        return await audioRecorder.stop()
    }

    func cancelPendingRecordingStart() async {}

    func pendingRecordingStartStatusMessage() async -> String? {
        nil
    }

    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState {
        if case .inactive = livePreviewRuntimeState,
           let unavailableReason = await streamingCoordinator.unavailablePreviewReason() {
            return .unavailable(unavailableReason)
        }

        return livePreviewRuntimeState
    }

    func normalizedInputLevel() async -> Float {
        await audioRecorder.normalizedInputLevel()
    }

    func isLivePreviewRequested() async -> Bool {
        let settings = await settingsSnapshotProvider()
        return WhisperKitStreamingModelLocator.isFeatureRequested(
            environment: environment,
            settings: settings
        )
    }

    func latestPreviewSnapshot() async -> StreamingPreviewSnapshot? {
        await streamingCoordinator.previewSnapshot()
    }

    func livePreviewUnavailableReason() async -> String? {
        await streamingCoordinator.unavailablePreviewReason()
    }

    func consumeFinalizedLiveTranscriptAfterStop() async -> String? {
        nil
    }

    func transcribePreparedRecording(
        _ recording: PreparedRecording,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        _ = statusHandler
        return try await whisperBridge.transcribe(samples: recording.samples)
    }
}
