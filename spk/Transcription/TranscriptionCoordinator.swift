import Foundation

struct StreamingTranscriptionUpdate: Sendable, Equatable {
    let transcript: String
    let decodeMilliseconds: Double
}

typealias WhisperStreamingUpdate = StreamingTranscriptionUpdate

struct TranscriptionPreparation: Sendable, Equatable {
    let resolvedModelURL: URL
    let readyDisplayName: String
}

actor TranscriptionCoordinator {
    enum CoordinatorError: LocalizedError {
        case noActiveSession
        case missingFallbackSamples

        var errorDescription: String? {
            switch self {
            case .noActiveSession:
                return "spk does not have an active transcription session."
            case .missingFallbackSamples:
                return "spk could not prepare the recorded audio for Whisper transcription."
            }
        }
    }

    private let whisperBridge: WhisperBridge
    private var hasActiveStreamingSession = false

    init(whisperBridge: WhisperBridge = WhisperBridge()) {
        self.whisperBridge = whisperBridge
    }

    func prepare() async throws -> TranscriptionPreparation {
        let modelURL = try await whisperBridge.prepareModel()
        return TranscriptionPreparation(
            resolvedModelURL: modelURL,
            readyDisplayName: modelURL.lastPathComponent
        )
    }

    func modelDirectoryURL() async throws -> URL {
        try await whisperBridge.modelDirectoryURL()
    }

    func startStreaming() async throws {
        try await whisperBridge.startStreaming()
        hasActiveStreamingSession = true
    }

    func enqueueStreamingSamples(_ samples: [Float]) async throws {
        guard hasActiveStreamingSession else {
            throw CoordinatorError.noActiveSession
        }

        try await whisperBridge.enqueueStreamingSamples(samples)
    }

    func takeStreamingUpdate() async throws -> StreamingTranscriptionUpdate? {
        guard hasActiveStreamingSession else {
            throw CoordinatorError.noActiveSession
        }

        return await whisperBridge.takeStreamingUpdate()
    }

    func finalizeStreaming(
        trailingSamples: [Float],
        fallbackFinalSamples: [Float]?
    ) async throws -> String {
        defer {
            hasActiveStreamingSession = false
        }

        if !trailingSamples.isEmpty, hasActiveStreamingSession {
            try await whisperBridge.enqueueStreamingSamples(trailingSamples)
        }
        await whisperBridge.stopStreaming()

        guard let fallbackFinalSamples else {
            throw CoordinatorError.missingFallbackSamples
        }

        return try await whisperBridge.transcribe(samples: fallbackFinalSamples)
    }

    func cancelStreaming() async {
        if hasActiveStreamingSession {
            await whisperBridge.stopStreaming()
        }

        hasActiveStreamingSession = false
    }
}
