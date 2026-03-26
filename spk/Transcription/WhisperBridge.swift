import Foundation
import whisper

struct WhisperStreamingConfiguration: Sendable {
    let minimumStepSamples: Int
    let maximumWindowSamples: Int
    let audioContext: Int32
    let maxTokens: Int32

    static let live = WhisperStreamingConfiguration(
        minimumStepSamples: 19_200,
        maximumWindowSamples: 72_000,
        audioContext: 512,
        maxTokens: 24
    )
}

actor WhisperBridge {
    enum WhisperBridgeError: LocalizedError {
        case couldNotCreateModelDirectory
        case modelDownloadFailed
        case invalidDownloadResponse
        case couldNotLoadModel
        case couldNotCreateDecoderState
        case transcriptionFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateModelDirectory:
                return "spk could not create a local model directory."
            case .modelDownloadFailed:
                return "spk could not download whisper-medium."
            case .invalidDownloadResponse:
                return "The whisper-medium download did not return a usable file."
            case .couldNotLoadModel:
                return "spk could not load the whisper-medium model."
            case .couldNotCreateDecoderState:
                return "spk could not allocate a Whisper decoder state."
            case .transcriptionFailed(let code):
                return "spk could not transcribe the recorded audio. whisper_full returned \(code)."
            }
        }
    }

    private static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private var streamingState: StreamingState?

    private struct StreamingState {
        let configuration: WhisperStreamingConfiguration
        let decoderState: OpaquePointer
        var pendingSamples: [Float] = []
        var rollingSamples: [Float] = []
        var pendingUpdate: WhisperStreamingUpdate?
        var receivedSampleCount = 0
        var drainedBatchCount = 0
        var decodeAttemptCount = 0
    }

    private struct TranscriptionRequest {
        let noContext: Bool
        let noTimestamps: Bool
        let singleSegment: Bool
        let detectLanguage: Bool
        let language: String
        let audioContext: Int32
        let maxTokens: Int32

        static let standard = TranscriptionRequest(
            noContext: true,
            noTimestamps: true,
            singleSegment: false,
            detectLanguage: false,
            language: "auto",
            audioContext: 0,
            maxTokens: 0
        )

        static func live(configuration: WhisperStreamingConfiguration) -> TranscriptionRequest {
            TranscriptionRequest(
                noContext: true,
                noTimestamps: true,
                singleSegment: true,
                detectLanguage: false,
                language: "auto",
                audioContext: configuration.audioContext,
                maxTokens: configuration.maxTokens
            )
        }
    }

    deinit {
        releaseStreamingState()
        if let context {
            whisper_free(context)
        }
    }

    func modelDirectoryURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "spk/Models")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("Failed to create model directory at \(directory.path): \(error)", category: "model")
            throw WhisperBridgeError.couldNotCreateModelDirectory
        }

        return directory
    }

    func prepareModel() async throws -> URL {
        let cachedModelURL = try cachedModelFileURL()

        let modelURL: URL
        if FileManager.default.fileExists(atPath: cachedModelURL.path) {
            DebugLog.log("Using cached model at \(cachedModelURL.path)", category: "model")
            modelURL = cachedModelURL
        } else if let bundledModelURL = bundledModelFileURL() {
            DebugLog.log("Using bundled model at \(bundledModelURL.path)", category: "model")
            modelURL = bundledModelURL
        } else {
            DebugLog.log("No local model found. Starting download to \(cachedModelURL.path)", category: "model")
            try await downloadModel(to: cachedModelURL)
            modelURL = cachedModelURL
        }

        try loadModelIfNeeded(at: modelURL)
        return modelURL
    }

    func transcribe(samples: [Float]) async throws -> String {
        let modelURL = try await prepareModel()
        try loadModelIfNeeded(at: modelURL)
        return try withFreshDecoderState(purpose: "final transcription") { state in
            try runTranscription(
                samples: samples,
                request: .standard,
                modelURL: modelURL,
                state: state,
                modeDescription: "final"
            )
        }
    }

    func startStreaming(configuration: WhisperStreamingConfiguration = .live) async throws {
        let modelURL = try await prepareModel()
        try loadModelIfNeeded(at: modelURL)
        releaseStreamingState()
        let decoderState = try makeDecoderState()
        streamingState = StreamingState(
            configuration: configuration,
            decoderState: decoderState
        )
        DebugLog.log(
            "Started live whisper streaming. minStepSamples=\(configuration.minimumStepSamples) maxWindowSamples=\(configuration.maximumWindowSamples) audioCtx=\(configuration.audioContext) maxTokens=\(configuration.maxTokens)",
            category: "transcription"
        )
    }

    func enqueueStreamingSamples(_ samples: [Float]) async throws {
        guard var streamingState else {
            DebugLog.log("Ignoring live samples because no whisper streaming session is active.", category: "transcription")
            return
        }

        guard !samples.isEmpty else {
            self.streamingState = streamingState
            return
        }

        streamingState.drainedBatchCount += 1
        streamingState.receivedSampleCount += samples.count
        streamingState.pendingSamples.append(contentsOf: samples)
        if streamingState.drainedBatchCount <= 3 || streamingState.drainedBatchCount % 10 == 0 {
            DebugLog.log(
                "Buffered live samples. batch=\(streamingState.drainedBatchCount) new=\(samples.count) pending=\(streamingState.pendingSamples.count) total=\(streamingState.receivedSampleCount)",
                category: "transcription"
            )
        }
        guard streamingState.pendingSamples.count >= streamingState.configuration.minimumStepSamples else {
            self.streamingState = streamingState
            return
        }

        let drainedCount = streamingState.pendingSamples.count
        streamingState.rollingSamples.append(contentsOf: streamingState.pendingSamples)
        streamingState.pendingSamples.removeAll(keepingCapacity: true)

        if streamingState.rollingSamples.count > streamingState.configuration.maximumWindowSamples {
            let overflow = streamingState.rollingSamples.count - streamingState.configuration.maximumWindowSamples
            streamingState.rollingSamples.removeFirst(overflow)
        }

        streamingState.decodeAttemptCount += 1
        self.streamingState = streamingState

        DebugLog.log(
            "Running live transcription update #\(streamingState.decodeAttemptCount). drained=\(drainedCount) windowSamples=\(streamingState.rollingSamples.count)",
            category: "transcription"
        )
        let clock = ContinuousClock()
        let startTime = clock.now
        let transcript = try runTranscription(
            samples: streamingState.rollingSamples,
            request: .live(configuration: streamingState.configuration),
            modelURL: try cachedOrBundledModelURL(),
            state: streamingState.decoderState,
            modeDescription: "live"
        )
        let decodeMilliseconds = milliseconds(for: startTime.duration(to: clock.now))
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        DebugLog.log(
            "Live whisper update completed. samples=\(streamingState.rollingSamples.count) decodeMs=\(String(format: "%.1f", decodeMilliseconds)) trimmedLength=\(trimmedTranscript.count)",
            category: "transcription"
        )

        guard !trimmedTranscript.isEmpty else {
            self.streamingState = streamingState
            return
        }

        streamingState.pendingUpdate = WhisperStreamingUpdate(
            transcript: trimmedTranscript,
            decodeMilliseconds: decodeMilliseconds
        )
        self.streamingState = streamingState
    }

    func takeStreamingUpdate() -> WhisperStreamingUpdate? {
        guard var streamingState else {
            return nil
        }

        let update = streamingState.pendingUpdate
        streamingState.pendingUpdate = nil
        self.streamingState = streamingState
        return update
    }

    func stopStreaming() {
        if streamingState != nil {
            DebugLog.log("Stopped live whisper streaming session.", category: "transcription")
        }
        releaseStreamingState()
    }

    private func cachedOrBundledModelURL() throws -> URL {
        let cachedModelURL = try cachedModelFileURL()
        if FileManager.default.fileExists(atPath: cachedModelURL.path) {
            return cachedModelURL
        }

        if let bundledModelURL = bundledModelFileURL() {
            return bundledModelURL
        }

        throw WhisperBridgeError.couldNotLoadModel
    }

    private func runTranscription(
        samples: [Float],
        request: TranscriptionRequest,
        modelURL: URL,
        state: OpaquePointer,
        modeDescription: String
    ) throws -> String {
        guard let context else {
            DebugLog.log("Transcription aborted because whisper context was nil after prepareModel.", category: "transcription")
            throw WhisperBridgeError.couldNotLoadModel
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = request.noContext
        params.no_timestamps = request.noTimestamps
        params.single_segment = request.singleSegment
        params.detect_language = request.detectLanguage
        params.language = nil
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        params.audio_ctx = request.audioContext
        params.max_tokens = request.maxTokens
        DebugLog.log(
            "Starting transcription. mode=\(modeDescription) samples=\(samples.count) n_threads=\(params.n_threads) model=\(modelURL.lastPathComponent) singleSegment=\(request.singleSegment) audioCtx=\(request.audioContext) maxTokens=\(request.maxTokens)",
            category: "transcription"
        )

        let result = request.language.withCString { languagePointer in
            var requestParams = params
            requestParams.language = languagePointer

            return samples.withUnsafeBufferPointer { buffer -> Int32 in
                whisper_reset_timings(context)
                return whisper_full_with_state(context, state, requestParams, buffer.baseAddress, Int32(buffer.count))
            }
        }

        guard result == 0 else {
            DebugLog.log("whisper_full failed with code \(result)", category: "transcription")
            throw WhisperBridgeError.transcriptionFailed(code: result)
        }

        let segmentCount = whisper_full_n_segments_from_state(state)
        let detectedLanguageID = whisper_full_lang_id_from_state(state)
        if detectedLanguageID >= 0, let detectedLanguagePointer = whisper_lang_str(detectedLanguageID) {
            let detectedLanguage = String(cString: detectedLanguagePointer)
            DebugLog.log("whisper resolved language=\(detectedLanguage)", category: "transcription")
        } else {
            DebugLog.log("whisper did not expose a resolved language for this transcription.", category: "transcription")
        }
        DebugLog.log("whisper_full succeeded. segments=\(segmentCount)", category: "transcription")

        if segmentCount == 0 {
            DebugLog.log(
                "whisper_full completed without segments. This indicates a transcription/decode failure, not an RMS silence rejection.",
                category: "transcription"
            )
        }

        let transcript = (0..<segmentCount).reduce(into: "") { partialResult, index in
            if let segment = whisper_full_get_segment_text_from_state(state, index) {
                partialResult += String(cString: segment)
            }
        }

        DebugLog.log("Transcript length after trimming: \(transcript.trimmingCharacters(in: .whitespacesAndNewlines).count)", category: "transcription")

        return transcript
    }

    private func withFreshDecoderState<T>(
        purpose: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let state = try makeDecoderState()
        defer {
            whisper_free_state(state)
        }

        DebugLog.log("Allocated isolated Whisper decoder state for \(purpose).", category: "transcription")
        return try body(state)
    }

    private func makeDecoderState() throws -> OpaquePointer {
        guard let context else {
            DebugLog.log("Cannot allocate a Whisper decoder state because the model context is nil.", category: "transcription")
            throw WhisperBridgeError.couldNotLoadModel
        }

        guard let state = whisper_init_state(context) else {
            DebugLog.log("whisper_init_state returned nil.", category: "transcription")
            throw WhisperBridgeError.couldNotCreateDecoderState
        }

        return state
    }

    private func releaseStreamingState() {
        guard let streamingState else { return }

        DebugLog.log(
            "Releasing live Whisper state. batches=\(streamingState.drainedBatchCount) totalSamples=\(streamingState.receivedSampleCount) decodeAttempts=\(streamingState.decodeAttemptCount) pending=\(streamingState.pendingSamples.count) rolling=\(streamingState.rollingSamples.count)",
            category: "transcription"
        )
        whisper_free_state(streamingState.decoderState)
        self.streamingState = nil
    }

    private func milliseconds(for duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000) + (Double(components.attoseconds) / 1e15)
    }

    private func cachedModelFileURL() throws -> URL {
        try modelDirectoryURL().appending(path: "ggml-medium.bin")
    }

    private func bundledModelFileURL() -> URL? {
        let bundle = Bundle.main

        let candidates = [
            bundle.url(forResource: "ggml-medium", withExtension: "bin", subdirectory: "Models"),
            bundle.url(forResource: "ggml-medium", withExtension: "bin")
        ]

        return candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func loadModelIfNeeded(at url: URL) throws {
        if loadedModelPath == url.path, context != nil {
            DebugLog.log("Model already loaded: \(url.path)", category: "model")
            return
        }

        releaseStreamingState()
        if let context {
            DebugLog.log("Freeing previous whisper context before loading \(url.path)", category: "model")
            whisper_free(context)
            self.context = nil
        }

        var params = whisper_context_default_params()
        // The vendored macOS Metal backend is crashing during app shutdown on this machine.
        // Prefer CPU mode until the embedded framework is updated to a stable GPU build.
        params.use_gpu = false
        params.flash_attn = false
        params.gpu_device = 0
        DebugLog.log("Loading whisper model from \(url.path) with GPU disabled.", category: "model")

        let modelContext = url.path.withCString { pathPointer in
            whisper_init_from_file_with_params_no_state(pathPointer, params)
        }

        guard let modelContext else {
            DebugLog.log("whisper_init_from_file_with_params returned nil for \(url.path)", category: "model")
            throw WhisperBridgeError.couldNotLoadModel
        }

        context = modelContext
        loadedModelPath = url.path
        DebugLog.log("Model loaded successfully from \(url.path)", category: "model")
    }

    private func downloadModel(to destinationURL: URL) async throws {
        let temporaryURL = destinationURL.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: temporaryURL)
        DebugLog.log("Downloading model from \(Self.modelDownloadURL.absoluteString)", category: "model")

        let (downloadedURL, response) = try await URLSession.shared.download(from: Self.modelDownloadURL)

        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            if let response = response as? HTTPURLResponse {
                DebugLog.log("Model download returned HTTP \(response.statusCode)", category: "model")
            } else {
                DebugLog.log("Model download returned a non-HTTP response.", category: "model")
            }
            throw WhisperBridgeError.invalidDownloadResponse
        }

        try? FileManager.default.removeItem(at: destinationURL)

        do {
            try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            DebugLog.log("Model download completed at \(destinationURL.path)", category: "model")
        } catch {
            DebugLog.log("Model download move failed: \(error)", category: "model")
            throw WhisperBridgeError.modelDownloadFailed
        }
    }
}
