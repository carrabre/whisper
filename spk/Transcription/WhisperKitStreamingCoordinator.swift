import Foundation
import WhisperKit

struct StreamingPreviewSnapshot: Sendable, Equatable {
    let confirmedText: String
    let unconfirmedText: String
    let currentText: String
    let latestRelativeEnergy: Float

    static let empty = StreamingPreviewSnapshot(
        confirmedText: "",
        unconfirmedText: "",
        currentText: "",
        latestRelativeEnergy: 0
    )

    var displayText: String {
        let tailText = !unconfirmedText.isEmpty ? unconfirmedText : currentText
        return Self.normalize([confirmedText, tailText].joined(separator: " "))
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor WhisperKitStreamingCoordinator {
    private enum SessionAvailability: Equatable {
        case unknown
        case ready
        case unavailable(String)
    }

    enum StreamingError: LocalizedError, Equatable {
        case unsupportedHardware
        case missingLocalModel
        case invalidModelPath(path: String)
        case tokenizerUnavailable
        case noTranscriptionResults

        var errorDescription: String? {
            switch self {
            case .unsupportedHardware:
                return "WhisperKit streaming preview currently requires Apple Silicon."
            case .missingLocalModel:
                return "spk could not find a local WhisperKit preview model. Choose one in Settings or bundle it with the app."
            case .invalidModelPath(let path):
                return "spk could not find a WhisperKit model folder at \(path)."
            case .tokenizerUnavailable:
                return "spk could not load the WhisperKit tokenizer from the configured local model folder."
            case .noTranscriptionResults:
                return "WhisperKit did not produce a preview transcript."
            }
        }
    }

    private static let minBufferDurationForPreview: Float = 0.08
    private static let previewPollSleepNanoseconds: UInt64 = 15_000_000
    private static let previewVoiceDetectionThreshold: Float = 0.12
    private static let previewTemperatureFallbackCount = 1
    private static let previewSampleLength = 128

    private let environment: [String: String]
    private let fileManager: FileManager
    private let audioDeviceManager: AudioDeviceManager
    private let bundle: Bundle
    private let settingsSnapshotProvider: @Sendable () async -> WhisperKitStreamingSettingsSnapshot

    private var whisperKit: WhisperKit?
    private var preparedModelFolderPath: String?
    private var realtimeTask: Task<Void, Never>?
    private var sessionAvailability: SessionAvailability = .unknown
    private var isRecording = false
    private var lastBufferSize = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var currentFallbacks = 0
    private var confirmedSegments: [TranscriptionSegment] = []
    private var unconfirmedSegments: [TranscriptionSegment] = []
    private var currentText = ""
    private var latestRelativeEnergy: Float = 0

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager(),
        bundle: Bundle = .main,
        settingsSnapshotProvider: @escaping @Sendable () async -> WhisperKitStreamingSettingsSnapshot = {
            .disabled
        }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.audioDeviceManager = audioDeviceManager
        self.bundle = bundle
        self.settingsSnapshotProvider = settingsSnapshotProvider
    }

    static func isPrototypeEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        WhisperKitStreamingModelLocator.isFeatureRequested(
            environment: environment,
            settings: .disabled
        )
    }

    func prepareIfNeeded() async throws -> URL? {
        let modelURL = try await resolvePreparedModelURL()
        let normalizedPath = modelURL.standardizedFileURL.path

        if whisperKit != nil, preparedModelFolderPath == normalizedPath {
            return modelURL
        }

        let config = WhisperKitConfig(
            modelFolder: normalizedPath,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )

        DebugLog.log("Preparing WhisperKit streaming preview from \(DebugLog.displayPath(modelURL))", category: "model")
        let resolvedWhisperKit = try await WhisperKit(config)
        guard resolvedWhisperKit.tokenizer != nil else {
            throw StreamingError.tokenizerUnavailable
        }

        whisperKit = resolvedWhisperKit
        preparedModelFolderPath = normalizedPath
        sessionAvailability = .ready
        resetPreviewState()
        return modelURL
    }

    func prepareForStartup() async {
        _ = await prepareIfAvailable(logContext: "startup")
    }

    func startIfAvailable(preferredInputDeviceID: String?) async throws -> Bool {
        guard await isFeatureRequested() else {
            return false
        }

        if isRecording {
            return true
        }

        guard await prepareIfAvailable(logContext: "recording start") != nil,
              let whisperKit
        else {
            return false
        }

        let resolvedInputDeviceID = try audioDeviceManager.resolveInputDeviceID(for: preferredInputDeviceID)

        resetPreviewState()
        currentText = "Waiting for speech..."
        updatePreviewSnapshot()

        DebugLog.log(
            "Starting WhisperKit streaming preview. preferredInput=\(preferredInputDeviceID ?? "system-default")",
            category: "transcription"
        )

        try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: resolvedInputDeviceID) { [self] _ in
            Task {
                onAudioBufferCallback()
            }
        }

        isRecording = true
        realtimeTask = Task { [weak self] in
            await self?.realtimeLoop()
        }

        return true
    }

    func stop() async -> [Float]? {
        guard isRecording || realtimeTask != nil else {
            return nil
        }

        isRecording = false
        realtimeTask?.cancel()
        _ = await realtimeTask?.value
        realtimeTask = nil

        let bufferedSamples = whisperKit.map { Array($0.audioProcessor.audioSamples) }
        whisperKit?.audioProcessor.stopRecording()
        resetPreviewState()

        if let bufferedSamples {
            DebugLog.log("Stopped WhisperKit streaming preview. samples=\(bufferedSamples.count)", category: "transcription")
        } else {
            DebugLog.log("Stopped WhisperKit streaming preview without buffered samples.", category: "transcription")
        }

        return bufferedSamples
    }

    func previewSnapshot() -> StreamingPreviewSnapshot? {
        guard case .ready = sessionAvailability, isRecording else {
            return nil
        }

        return StreamingPreviewSnapshot(
            confirmedText: normalizedText(from: confirmedSegments.map(\.text).joined()),
            unconfirmedText: normalizedText(from: unconfirmedSegments.map(\.text).joined()),
            currentText: normalizedText(from: currentText),
            latestRelativeEnergy: latestRelativeEnergy
        )
    }

    func normalizedInputLevel() -> Float {
        guard case .ready = sessionAvailability, isRecording else {
            return 0
        }

        return latestRelativeEnergy
    }

    func unavailablePreviewReason() async -> String? {
        guard await isFeatureRequested() else {
            return nil
        }

        switch sessionAvailability {
        case .unavailable(let message):
            return message
        case .ready:
            return nil
        case .unknown:
            switch await currentModelResolution() {
            case .disabled, .ready:
                return nil
            case .unsupportedHardware:
                return StreamingError.unsupportedHardware.localizedDescription
            case .missingModel:
                return StreamingError.missingLocalModel.localizedDescription
            case .invalidEnvironmentPath(let path), .invalidCustomPath(let path):
                return StreamingError.invalidModelPath(path: path).localizedDescription
            }
        }
    }

    private func realtimeLoop() async {
        while isRecording && !Task.isCancelled {
            do {
                try await transcribeCurrentBuffer()
            } catch is CancellationError {
                break
            } catch {
                DebugLog.log("WhisperKit streaming preview paused after error: \(error)", category: "transcription")
                if confirmedSegments.isEmpty && unconfirmedSegments.isEmpty {
                    currentText = "Live preview unavailable."
                    updatePreviewSnapshot()
                }
                break
            }
        }
    }

    private func onAudioBufferCallback() {
        updateRelativeEnergy()
        updatePreviewSnapshot()
    }

    private func onProgressCallback(_ progress: TranscriptionProgress) {
        let fallbacks = Int(progress.timings.totalDecodingFallbacks)
        if progress.text.count < currentText.count, fallbacks != currentFallbacks {
            DebugLog.log("WhisperKit streaming preview fallback occurred: \(fallbacks)", category: "transcription")
        }

        currentText = normalizedText(from: progress.text)
        currentFallbacks = fallbacks
        updatePreviewSnapshot()
    }

    private func transcribeCurrentBuffer() async throws {
        guard let whisperKit else { return }

        let currentBuffer = whisperKit.audioProcessor.audioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        guard nextBufferSeconds > Self.minBufferDurationForPreview else {
            setWaitingForSpeechIfNeeded()
            try await Task.sleep(nanoseconds: Self.previewPollSleepNanoseconds)
            return
        }

        let voiceDetected = AudioProcessor.isVoiceDetected(
            in: whisperKit.audioProcessor.relativeEnergy,
            nextBufferInSeconds: nextBufferSeconds,
            silenceThreshold: Self.previewVoiceDetectionThreshold
        )

        guard voiceDetected else {
            setWaitingForSpeechIfNeeded()
            try await Task.sleep(nanoseconds: Self.previewPollSleepNanoseconds)
            return
        }

        lastBufferSize = currentBuffer.count
        let transcription = try await transcribeAudioSamples(Array(currentBuffer))

        currentText = ""
        let segments = transcription.segments

        if segments.count > 2 {
            let confirmed = Array(segments.prefix(segments.count - 2))
            let remaining = Array(segments.suffix(2))

            if let lastConfirmedSegment = confirmed.last,
               lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                let newConfirmedSegments = confirmed.filter { $0.end > lastConfirmedSegmentEndSeconds }
                confirmedSegments.append(contentsOf: newConfirmedSegments)
                lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
            }

            unconfirmedSegments = remaining
        } else {
            unconfirmedSegments = segments
        }

        updatePreviewSnapshot()
    }

    private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw StreamingError.noTranscriptionResults
        }

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperatureFallbackCount: Self.previewTemperatureFallbackCount,
            sampleLength: Self.previewSampleLength,
            usePrefillPrompt: false,
            skipSpecialTokens: true,
            chunkingStrategy: ChunkingStrategy.none
        )
        options.clipTimestamps = [lastConfirmedSegmentEndSeconds]

        let compressionCheckWindow = 60
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: { [self] progress in
            Task {
                onProgressCallback(progress)
            }
            return Self.shouldStopEarly(progress: progress, options: options, compressionCheckWindow: compressionCheckWindow)
        },
            segmentCallback: nil
        )

        guard let result = results.first else {
            throw StreamingError.noTranscriptionResults
        }

        return result
    }

    private func prepareIfAvailable(logContext: String) async -> URL? {
        guard await isFeatureRequested() else {
            return nil
        }

        do {
            return try await prepareIfNeeded()
        } catch {
            disableForSession(error: error, logContext: logContext)
            return nil
        }
    }

    private func resolvePreparedModelURL() async throws -> URL {
        switch await currentModelResolution() {
        case .disabled:
            throw StreamingError.missingLocalModel
        case .unsupportedHardware:
            throw StreamingError.unsupportedHardware
        case .ready(let resolvedModel):
            return resolvedModel.url
        case .invalidEnvironmentPath(let path), .invalidCustomPath(let path):
            throw StreamingError.invalidModelPath(path: path)
        case .missingModel:
            throw StreamingError.missingLocalModel
        }
    }

    private func resetPreviewState() {
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        currentFallbacks = 0
        confirmedSegments = []
        unconfirmedSegments = []
        currentText = ""
        latestRelativeEnergy = 0
    }

    private func disableForSession(error: Error, logContext: String) {
        sessionAvailability = .unavailable(error.localizedDescription)
        whisperKit = nil
        preparedModelFolderPath = nil
        resetPreviewState()

        DebugLog.log(
            "WhisperKit streaming preview disabled for this app session during \(logContext): \(error.localizedDescription). Falling back to standard recording/transcription.",
            category: "transcription"
        )
    }

    private func currentModelResolution() async -> WhisperKitStreamingModelResolution {
        WhisperKitStreamingModelLocator.resolveModel(
            environment: environment,
            settings: await settingsSnapshotProvider(),
            fileManager: fileManager,
            bundle: bundle
        )
    }

    private func isFeatureRequested() async -> Bool {
        WhisperKitStreamingModelLocator.isFeatureRequested(
            environment: environment,
            settings: await settingsSnapshotProvider()
        )
    }

    private func setWaitingForSpeechIfNeeded() {
        guard confirmedSegments.isEmpty && unconfirmedSegments.isEmpty else {
            return
        }

        currentText = "Waiting for speech..."
        updatePreviewSnapshot()
    }

    private func updateRelativeEnergy() {
        latestRelativeEnergy = whisperKit?.audioProcessor.relativeEnergy.last ?? 0
    }

    private func updatePreviewSnapshot() {
        updateRelativeEnergy()
    }

    private func normalizedText(from text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldStopEarly(
        progress: TranscriptionProgress,
        options: DecodingOptions,
        compressionCheckWindow: Int
    ) -> Bool? {
        let currentTokens = progress.tokens
        if currentTokens.count > compressionCheckWindow {
            let checkTokens: [Int] = currentTokens.suffix(compressionCheckWindow)
            let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
            if compressionRatio > options.compressionRatioThreshold ?? 0.0 {
                return false
            }
        }

        if let avgLogprob = progress.avgLogprob, let logProbThreshold = options.logProbThreshold {
            if avgLogprob < logProbThreshold {
                return false
            }
        }

        return nil
    }

}
