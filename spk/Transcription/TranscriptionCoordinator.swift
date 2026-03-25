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
                return "spk could not prepare the recorded audio for multilingual Whisper transcription."
            }
        }
    }

    private enum ActiveBackend: Sendable {
        case nemotron
        case whisper
    }

    private let whisperBridge: WhisperBridge
    private let nemotronBridge: NemotronBridge
    private var activeBackend: ActiveBackend?

    init(
        whisperBridge: WhisperBridge = WhisperBridge(),
        nemotronBridge: NemotronBridge = NemotronBridge()
    ) {
        self.whisperBridge = whisperBridge
        self.nemotronBridge = nemotronBridge
    }

    func prepare(mode: TranscriptionMode) async throws -> TranscriptionPreparation {
        switch mode {
        case .englishRealtimeNemotron:
            let modelURL = try await nemotronBridge.prepareModel()
            return TranscriptionPreparation(
                resolvedModelURL: modelURL,
                readyDisplayName: "Nemotron English \(modelURL.lastPathComponent)"
            )
        case .multilingualWhisper:
            let modelURL = try await whisperBridge.prepareModel()
            return TranscriptionPreparation(
                resolvedModelURL: modelURL,
                readyDisplayName: modelURL.lastPathComponent
            )
        }
    }

    func modelDirectoryURL(mode: TranscriptionMode) async throws -> URL {
        switch mode {
        case .englishRealtimeNemotron:
            return try await nemotronBridge.modelDirectoryURL()
        case .multilingualWhisper:
            return try await whisperBridge.modelDirectoryURL()
        }
    }

    func startStreaming(mode: TranscriptionMode) async throws {
        switch mode {
        case .englishRealtimeNemotron:
            try await nemotronBridge.startStreaming()
            activeBackend = .nemotron
        case .multilingualWhisper:
            try await whisperBridge.startStreaming()
            activeBackend = .whisper
        }
    }

    func appendStreamingSamples(_ samples: [Float]) async throws -> StreamingTranscriptionUpdate? {
        switch activeBackend {
        case .nemotron:
            return try await nemotronBridge.appendStreamingSamples(samples)
        case .whisper:
            return try await whisperBridge.appendStreamingSamples(samples)
        case .none:
            throw CoordinatorError.noActiveSession
        }
    }

    func finalizeStreaming(
        mode: TranscriptionMode,
        trailingSamples: [Float],
        fallbackFinalSamples: [Float]?
    ) async throws -> String {
        defer {
            activeBackend = nil
        }

        switch mode {
        case .englishRealtimeNemotron:
            guard activeBackend == .nemotron else {
                throw CoordinatorError.noActiveSession
            }
            return try await nemotronBridge.finalizeStreaming(trailingSamples: trailingSamples)

        case .multilingualWhisper:
            if !trailingSamples.isEmpty, activeBackend == .whisper {
                _ = try await whisperBridge.appendStreamingSamples(trailingSamples)
            }
            await whisperBridge.stopStreaming()

            guard let fallbackFinalSamples else {
                throw CoordinatorError.missingFallbackSamples
            }

            return try await whisperBridge.transcribe(samples: fallbackFinalSamples)
        }
    }

    func cancelStreaming() async {
        switch activeBackend {
        case .nemotron:
            await nemotronBridge.stopStreaming()
        case .whisper:
            await whisperBridge.stopStreaming()
        case .none:
            break
        }

        activeBackend = nil
    }
}
