import Foundation

actor TranscriptionCoordinator {
    private let whisperBackend: WhisperTranscriptionBackend
    private let voxtralRealtimeBackend: VoxtralRealtimeTranscriptionBackend
    private let selectionProvider: @Sendable () async -> TranscriptionBackendSelection

    init(
        whisperBackend: WhisperTranscriptionBackend,
        voxtralRealtimeBackend: VoxtralRealtimeTranscriptionBackend,
        selectionProvider: @escaping @Sendable () async -> TranscriptionBackendSelection
    ) {
        self.whisperBackend = whisperBackend
        self.voxtralRealtimeBackend = voxtralRealtimeBackend
        self.selectionProvider = selectionProvider
    }

    func selectedBackend() async -> TranscriptionBackendSelection {
        await selectionProvider()
    }

    func prepare() async throws -> TranscriptionPreparation {
        switch await selectionProvider() {
        case .whisper:
            return try await whisperBackend.prepare()
        case .voxtralRealtime:
            return try await voxtralRealtimeBackend.prepare()
        }
    }

    func preparationProgress() async -> TranscriptionPreparationProgress? {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.preparationProgress()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.preparationProgress()
        }
    }

    func invalidatePreparation() async {
        await whisperBackend.invalidatePreparation()
        await voxtralRealtimeBackend.invalidatePreparation()
    }

    func modelDirectoryURL() async throws -> URL {
        switch await selectionProvider() {
        case .whisper:
            return try await whisperBackend.modelDirectoryURL()
        case .voxtralRealtime:
            return try await voxtralRealtimeBackend.modelDirectoryURL()
        }
    }

    func startRecording(preferredInputDeviceID: String?) async throws -> RecordingStartResult {
        switch await selectionProvider() {
        case .whisper:
            return try await whisperBackend.startRecording(preferredInputDeviceID: preferredInputDeviceID)
        case .voxtralRealtime:
            return try await voxtralRealtimeBackend.startRecording(preferredInputDeviceID: preferredInputDeviceID)
        }
    }

    func cancelPendingRecordingStart() async {
        switch await selectionProvider() {
        case .whisper:
            await whisperBackend.cancelPendingRecordingStart()
        case .voxtralRealtime:
            await voxtralRealtimeBackend.cancelPendingRecordingStart()
        }
    }

    func stopRecording() async -> RecordingStopResult {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.stopRecording()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.stopRecording()
        }
    }

    func pendingRecordingStartStatusMessage() async -> String? {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.pendingRecordingStartStatusMessage()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.pendingRecordingStartStatusMessage()
        }
    }

    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.currentLivePreviewRuntimeState()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.currentLivePreviewRuntimeState()
        }
    }

    func normalizedInputLevel() async -> Float {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.normalizedInputLevel()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.normalizedInputLevel()
        }
    }

    func isLivePreviewRequested() async -> Bool {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.isLivePreviewRequested()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.isLivePreviewRequested()
        }
    }

    func latestPreviewSnapshot() async -> StreamingPreviewSnapshot? {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.latestPreviewSnapshot()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.latestPreviewSnapshot()
        }
    }

    func livePreviewUnavailableReason() async -> String? {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.livePreviewUnavailableReason()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.livePreviewUnavailableReason()
        }
    }

    func transcribePreparedRecording(
        _ recording: PreparedRecording,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        switch await selectionProvider() {
        case .whisper:
            return try await whisperBackend.transcribePreparedRecording(
                recording,
                statusHandler: statusHandler
            )
        case .voxtralRealtime:
            return try await voxtralRealtimeBackend.transcribePreparedRecording(
                recording,
                statusHandler: statusHandler
            )
        }
    }
}
