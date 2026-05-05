import Foundation

actor TranscriptionCoordinator {
    private let whisperBackend: any TranscriptionBackend
    private let voxtralRealtimeBackend: any TranscriptionBackend
    private let selectionProvider: @Sendable () async -> TranscriptionBackendSelection
    private var activeRecordingBackendSelection: TranscriptionBackendSelection?

    init(
        whisperBackend: any TranscriptionBackend,
        voxtralRealtimeBackend: any TranscriptionBackend,
        selectionProvider: @escaping @Sendable () async -> TranscriptionBackendSelection
    ) {
        self.whisperBackend = whisperBackend
        self.voxtralRealtimeBackend = voxtralRealtimeBackend
        self.selectionProvider = selectionProvider
    }

    func selectedBackend() async -> TranscriptionBackendSelection {
        await selectionProvider()
    }

    private func recordingScopedBackendSelection() async -> TranscriptionBackendSelection {
        if let activeRecordingBackendSelection {
            return activeRecordingBackendSelection
        }

        return await selectionProvider()
    }

    func prepare() async throws -> TranscriptionPreparation {
        switch await selectionProvider() {
        case .whisper:
            return try await whisperBackend.prepare()
        case .voxtralRealtime:
            return try await voxtralRealtimeBackend.prepare()
        }
    }

    func isReadyForImmediateRecordingStart() async -> Bool {
        switch await selectionProvider() {
        case .whisper:
            return await whisperBackend.isReadyForImmediateRecordingStart()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.isReadyForImmediateRecordingStart()
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
        let selectedBackend = await selectionProvider()
        activeRecordingBackendSelection = selectedBackend

        do {
            switch selectedBackend {
            case .whisper:
                return try await whisperBackend.startRecording(preferredInputDeviceID: preferredInputDeviceID)
            case .voxtralRealtime:
                return try await voxtralRealtimeBackend.startRecording(preferredInputDeviceID: preferredInputDeviceID)
            }
        } catch {
            activeRecordingBackendSelection = nil
            throw error
        }
    }

    func cancelPendingRecordingStart() async {
        switch await recordingScopedBackendSelection() {
        case .whisper:
            await whisperBackend.cancelPendingRecordingStart()
        case .voxtralRealtime:
            await voxtralRealtimeBackend.cancelPendingRecordingStart()
        }

        activeRecordingBackendSelection = nil
    }

    func stopRecording() async -> RecordingStopResult {
        let selectedBackend = await recordingScopedBackendSelection()
        let stopResult: RecordingStopResult

        switch selectedBackend {
        case .whisper:
            stopResult = await whisperBackend.stopRecording()
        case .voxtralRealtime:
            stopResult = await voxtralRealtimeBackend.stopRecording()
        }

        if selectedBackend == .voxtralRealtime {
            activeRecordingBackendSelection = nil
        }

        return stopResult
    }

    func pendingRecordingStartStatusMessage() async -> String? {
        switch await recordingScopedBackendSelection() {
        case .whisper:
            return await whisperBackend.pendingRecordingStartStatusMessage()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.pendingRecordingStartStatusMessage()
        }
    }

    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState {
        switch await recordingScopedBackendSelection() {
        case .whisper:
            return await whisperBackend.currentLivePreviewRuntimeState()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.currentLivePreviewRuntimeState()
        }
    }

    func normalizedInputLevel() async -> Float {
        switch await recordingScopedBackendSelection() {
        case .whisper:
            return await whisperBackend.normalizedInputLevel()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.normalizedInputLevel()
        }
    }

    func recordingRuntimeSnapshot() async -> RecordingRuntimeSnapshot {
        switch await recordingScopedBackendSelection() {
        case .whisper:
            return await whisperBackend.recordingRuntimeSnapshot()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.recordingRuntimeSnapshot()
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
        switch await recordingScopedBackendSelection() {
        case .whisper:
            return await whisperBackend.latestPreviewSnapshot()
        case .voxtralRealtime:
            return await voxtralRealtimeBackend.latestPreviewSnapshot()
        }
    }

    func livePreviewUnavailableReason() async -> String? {
        switch await recordingScopedBackendSelection() {
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
        let selectedBackend = await recordingScopedBackendSelection()
        defer {
            activeRecordingBackendSelection = nil
        }

        switch selectedBackend {
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
