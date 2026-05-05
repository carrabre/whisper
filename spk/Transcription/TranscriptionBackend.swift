import Foundation

enum TranscriptionBackendSelection: String, CaseIterable, Identifiable, Sendable {
    case whisper
    case voxtralRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .voxtralRealtime:
            return "Voxtral Realtime"
        }
    }

    var settingsDescription: String {
        switch self {
        case .whisper:
            return "Whisper uses only bundled or locally installed model files for dictation on this Mac. It records first and produces the final transcript after you stop. The app never downloads models at runtime."
        case .voxtralRealtime:
            return "Voxtral Realtime is the fastest local realtime dictation option on this Mac. It uses a local helper process plus a local model folder, and the app never starts a remote inference server or downloads models at runtime."
        }
    }
}

struct TranscriptionPreparation: Sendable, Equatable {
    let resolvedModelURL: URL
    let readyDisplayName: String
}

enum TranscriptionPreparationStage: String, Sendable, Equatable {
    case locatingModel
    case launchingHelper
    case loadingModel
    case warmingStreaming
    case ready
}

struct TranscriptionPreparationProgress: Sendable, Equatable {
    let stage: TranscriptionPreparationStage
    let fraction: Double
    let detail: String
}

struct RecordingRuntimeSnapshot: Sendable, Equatable {
    let normalizedInputLevel: Float
    let livePreviewState: LivePreviewRuntimeState
    let previewSnapshot: StreamingPreviewSnapshot?
    let unavailableReason: String?

    static let inactive = RecordingRuntimeSnapshot(
        normalizedInputLevel: 0,
        livePreviewState: .inactive,
        previewSnapshot: nil,
        unavailableReason: nil
    )
}

enum LivePreviewRuntimeState: Sendable, Equatable {
    case inactive
    case prewarming(String)
    case active
    case unavailable(String)
    case unavailableButFinalTranscriptAvailable(String)

    var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }

    var isPrewarming: Bool {
        if case .prewarming = self {
            return true
        }
        return false
    }

    var unavailableReason: String? {
        switch self {
        case .unavailable(let reason), .unavailableButFinalTranscriptAvailable(let reason):
            return reason
        default:
            return nil
        }
    }

    var finalTranscriptAvailableOnStop: Bool {
        if case .unavailableButFinalTranscriptAvailable = self {
            return true
        }
        return false
    }
}

struct RecordingStartResult: Sendable, Equatable {
    let livePreviewState: LivePreviewRuntimeState
    let inputStatusMessage: String?

    init(
        livePreviewState: LivePreviewRuntimeState,
        inputStatusMessage: String? = nil
    ) {
        self.livePreviewState = livePreviewState
        self.inputStatusMessage = inputStatusMessage
    }

    static let inactive = RecordingStartResult(livePreviewState: .inactive)
    static let active = RecordingStartResult(livePreviewState: .active)
}

enum TranscriptionBackendAvailability: Sendable, Equatable {
    case ready(String)
    case unavailable(String)
}

protocol StreamingAudioCaptureCoordinating: Sendable {
    func startIfAvailable(preferredInputDeviceID: String?, recordingURL: URL) async throws -> Bool
    func stop() async -> RecordingStopResult?
    func currentRecordingURL() async -> URL?
    func previewSnapshot() async -> StreamingPreviewSnapshot?
}

actor NoopStreamingCaptureCoordinator: StreamingAudioCaptureCoordinating {
    func startIfAvailable(preferredInputDeviceID: String?, recordingURL: URL) async throws -> Bool {
        false
    }

    func stop() async -> RecordingStopResult? {
        nil
    }

    func currentRecordingURL() async -> URL? {
        nil
    }

    func previewSnapshot() async -> StreamingPreviewSnapshot? {
        nil
    }
}

protocol TranscriptionBackend: Sendable {
    var selection: TranscriptionBackendSelection { get }

    func prepare() async throws -> TranscriptionPreparation
    func isReadyForImmediateRecordingStart() async -> Bool
    func preparationProgress() async -> TranscriptionPreparationProgress?
    func invalidatePreparation() async
    func modelDirectoryURL() async throws -> URL
    func startRecording(preferredInputDeviceID: String?) async throws -> RecordingStartResult
    func cancelPendingRecordingStart() async
    func stopRecording() async -> RecordingStopResult
    func pendingRecordingStartStatusMessage() async -> String?
    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState
    func normalizedInputLevel() async -> Float
    func isLivePreviewRequested() async -> Bool
    func latestPreviewSnapshot() async -> StreamingPreviewSnapshot?
    func livePreviewUnavailableReason() async -> String?
    func transcribePreparedRecording(
        _ recording: PreparedRecording,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String
}

extension TranscriptionBackend {
    func recordingRuntimeSnapshot() async -> RecordingRuntimeSnapshot {
        let livePreviewState = await currentLivePreviewRuntimeState()
        let previewSnapshot = livePreviewState.isActive ? await latestPreviewSnapshot() : nil
        let unavailableReason: String?
        if let stateReason = livePreviewState.unavailableReason {
            unavailableReason = stateReason
        } else {
            unavailableReason = await livePreviewUnavailableReason()
        }
        return RecordingRuntimeSnapshot(
            normalizedInputLevel: await normalizedInputLevel(),
            livePreviewState: livePreviewState,
            previewSnapshot: previewSnapshot,
            unavailableReason: unavailableReason
        )
    }
}
