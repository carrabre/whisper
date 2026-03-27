import Foundation

struct TranscriptionPreparation: Sendable, Equatable {
    let resolvedModelURL: URL
    let readyDisplayName: String
}

actor TranscriptionCoordinator {
    private let whisperBridge: WhisperBridge
    private let streamingCoordinator: WhisperKitStreamingCoordinator

    init(
        whisperBridge: WhisperBridge = WhisperBridge(),
        streamingCoordinator: WhisperKitStreamingCoordinator = WhisperKitStreamingCoordinator()
    ) {
        self.whisperBridge = whisperBridge
        self.streamingCoordinator = streamingCoordinator
    }

    func prepare() async throws -> TranscriptionPreparation {
        let modelURL = try await whisperBridge.prepareModel()
        await streamingCoordinator.prepareForStartup()
        return TranscriptionPreparation(
            resolvedModelURL: modelURL,
            readyDisplayName: modelURL.lastPathComponent
        )
    }

    func modelDirectoryURL() async throws -> URL {
        try await whisperBridge.modelDirectoryURL()
    }

    func transcribePreparedRecording(samples: [Float]) async throws -> String {
        try await whisperBridge.transcribe(samples: samples)
    }
}
