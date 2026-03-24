import Foundation
import whisper

actor WhisperBridge {
    enum WhisperBridgeError: LocalizedError {
        case couldNotCreateModelDirectory
        case modelDownloadFailed
        case invalidDownloadResponse
        case couldNotLoadModel
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
            case .transcriptionFailed(let code):
                return "spk could not transcribe the recorded audio. whisper_full returned \(code)."
            }
        }
    }

    private static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!

    private var context: OpaquePointer?
    private var loadedModelPath: String?

    deinit {
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
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = false
        params.detect_language = false
        params.language = nil
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        DebugLog.log(
            "Starting transcription. samples=\(samples.count) n_threads=\(params.n_threads) model=\(modelURL.lastPathComponent)",
            category: "transcription"
        )

        let result = "auto".withCString { autoLanguagePointer in
            var requestParams = params
            requestParams.language = autoLanguagePointer

            return samples.withUnsafeBufferPointer { buffer -> Int32 in
                whisper_reset_timings(context)
                return whisper_full(context, requestParams, buffer.baseAddress, Int32(buffer.count))
            }
        }

        guard result == 0 else {
            DebugLog.log("whisper_full failed with code \(result)", category: "transcription")
            throw WhisperBridgeError.transcriptionFailed(code: result)
        }

        let segmentCount = whisper_full_n_segments(context)
        let detectedLanguageID = whisper_full_lang_id(context)
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
            if let segment = whisper_full_get_segment_text(context, index) {
                partialResult += String(cString: segment)
            }
        }

        DebugLog.log("Transcript length after trimming: \(transcript.trimmingCharacters(in: .whitespacesAndNewlines).count)", category: "transcription")

        return transcript
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
            whisper_init_from_file_with_params(pathPointer, params)
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
