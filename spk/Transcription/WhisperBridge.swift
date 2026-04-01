import Foundation
import whisper

actor WhisperBridge {
    private struct WhisperModelVariant: Sendable, Equatable {
        let id: String

        var fileName: String {
            "ggml-\(id).bin"
        }

        var displayName: String {
            "whisper-\(id)"
        }

        var isEnglishOnly: Bool {
            id.contains(".en")
        }
    }

    private struct WhisperVADModel: Sendable {
        let id: String

        var fileName: String {
            "ggml-\(id).bin"
        }
    }

    enum WhisperBridgeError: LocalizedError, Equatable {
        case couldNotCreateModelDirectory
        case modelUnavailableLocally(fileName: String)
        case couldNotLoadModel
        case couldNotCreateDecoderState
        case transcriptionFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateModelDirectory:
                return "spk could not create a local model directory."
            case .modelUnavailableLocally(let fileName):
                return "spk could not find \(fileName) locally. Bundle it with the app or install it in ~/Library/Application Support/spk/Models before launching."
            case .couldNotLoadModel:
                return "spk could not load the configured Whisper model."
            case .couldNotCreateDecoderState:
                return "spk could not allocate a Whisper decoder state."
            case .transcriptionFailed(let code):
                return "spk could not transcribe the recorded audio. whisper_full returned \(code)."
            }
        }
    }

    private static let modelOverrideEnvironmentKey = "SPK_WHISPER_MODEL"
    private static let modelPathOverrideEnvironmentKey = "SPK_WHISPER_MODEL_PATH"
    private static let useGPUEnvironmentKey = "SPK_WHISPER_USE_GPU"
    private static let vadPathOverrideEnvironmentKey = "SPK_WHISPER_VAD_MODEL_PATH"
    private static let defaultEnglishPrimaryModel = WhisperModelVariant(id: "base.en-q5_1")
    private static let defaultMultilingualPrimaryModel = WhisperModelVariant(id: "base-q5_1")
    private static let englishFallbackModels = [
        WhisperModelVariant(id: "base.en"),
        WhisperModelVariant(id: "small.en-q5_1"),
        WhisperModelVariant(id: "small.en"),
        WhisperModelVariant(id: "medium.en-q5_0"),
        WhisperModelVariant(id: "medium.en"),
        WhisperModelVariant(id: "medium-q5_0"),
        WhisperModelVariant(id: "medium")
    ]
    private static let multilingualFallbackModels = [
        WhisperModelVariant(id: "base"),
        WhisperModelVariant(id: "small-q5_1"),
        WhisperModelVariant(id: "small"),
        WhisperModelVariant(id: "medium-q5_0"),
        WhisperModelVariant(id: "medium")
    ]
    private static let vadModel = WhisperVADModel(id: "silero-v6.2.0")

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private var loadedModelVariant: WhisperModelVariant?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let modelDirectoryOverrideURL: URL?
    private let bundledFileURLOverrides: [String: URL]
    private let allowBundledFileLookup: Bool

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        modelDirectoryOverrideURL: URL? = nil,
        bundledFileURLOverrides: [String: URL] = [:],
        allowBundledFileLookup: Bool = true
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.modelDirectoryOverrideURL = modelDirectoryOverrideURL
        self.bundledFileURLOverrides = bundledFileURLOverrides
        self.allowBundledFileLookup = allowBundledFileLookup
    }

    private struct TranscriptionRequest {
        let noContext: Bool
        let noTimestamps: Bool
        let singleSegment: Bool
        let detectLanguage: Bool
        let language: String
        let audioContext: Int32
        let maxTokens: Int32
        let useVAD: Bool

        static func standard(model: WhisperModelVariant) -> TranscriptionRequest {
            TranscriptionRequest(
                noContext: true,
                noTimestamps: true,
                singleSegment: true,
                detectLanguage: false,
                language: model.isEnglishOnly ? "en" : "auto",
                audioContext: 0,
                maxTokens: 0,
                useVAD: true
            )
        }
    }

    static func defaultModelDisplayName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        preferredModelVariants(environment: environment).first?.displayName ?? defaultEnglishPrimaryModel.displayName
    }

    static func defaultModelFileName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        preferredModelVariants(environment: environment).first?.fileName ?? defaultEnglishPrimaryModel.fileName
    }

    static var defaultModelDisplayName: String {
        defaultModelDisplayName()
    }

    static var defaultModelFileName: String {
        defaultModelFileName()
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    func modelDirectoryURL() throws -> URL {
        let directory = try rawModelDirectoryURL()

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("Failed to create model directory at \(DebugLog.displayPath(directory)): \(error)", category: "model")
            throw WhisperBridgeError.couldNotCreateModelDirectory
        }

        return directory
    }

    func prepareModel() async throws -> URL {
        let resolvedModel = try resolveLocalModelSelection()
        try loadModelIfNeeded(at: resolvedModel.url)
        loadedModelVariant = resolvedModel.variant
        return resolvedModel.url
    }

    func transcribe(samples: [Float]) async throws -> String {
        let modelURL = try await prepareModel()
        try loadModelIfNeeded(at: modelURL)
        let modelVariant = loadedModelVariant ?? Self.preferredModelVariants(environment: environment)[0]

        return try withFreshDecoderState(purpose: "final transcription") { state in
            try runTranscription(
                samples: samples,
                request: .standard(model: modelVariant),
                modelURL: modelURL,
                state: state,
                modeDescription: "final"
            )
        }
    }

    func resolveModelURLForTesting() throws -> URL {
        try resolveLocalModelSelection().url
    }

    func resolveVADModelURLForTesting() throws -> URL? {
        try availableVADModelURL()
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
        params.greedy.best_of = 1
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0
        params.no_speech_thold = 0.6

        var duplicatedVADModelPath: UnsafeMutablePointer<CChar>?
        if request.useVAD, let vadModelURL = try? availableVADModelURL() {
            params.vad = true
            duplicatedVADModelPath = strdup(vadModelURL.path)
            if let duplicatedVADModelPath {
                params.vad_model_path = UnsafePointer(duplicatedVADModelPath)
            }
            params.vad_params = whisper_vad_default_params()
            params.vad_params.min_silence_duration_ms = 250
            params.vad_params.speech_pad_ms = 120
        } else if request.useVAD {
            DebugLog.log("Voice activity detection is unavailable locally. Continuing without a bundled or cached VAD model.", category: "model")
        }

        DebugLog.log(
            "Starting transcription. mode=\(modeDescription) samples=\(samples.count) n_threads=\(params.n_threads) model=\(modelURL.lastPathComponent) singleSegment=\(request.singleSegment) audioCtx=\(request.audioContext) maxTokens=\(request.maxTokens) vad=\(params.vad)",
            category: "transcription"
        )

        defer {
            if let duplicatedVADModelPath {
                free(duplicatedVADModelPath)
            }
        }

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

    private func rawModelDirectoryURL() throws -> URL {
        if let modelDirectoryOverrideURL {
            return modelDirectoryOverrideURL
        }

        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "spk/Models")
    }

    private func cachedModelFileURL(for variant: WhisperModelVariant) throws -> URL {
        try rawModelDirectoryURL().appending(path: variant.fileName)
    }

    private func cachedVADModelFileURL() throws -> URL {
        try rawModelDirectoryURL().appending(path: Self.vadModel.fileName)
    }

    private func bundledModelFileURL(for variant: WhisperModelVariant) -> URL? {
        bundledFileURL(forFileName: variant.fileName)
    }

    private func bundledVADModelFileURL() -> URL? {
        bundledFileURL(forFileName: Self.vadModel.fileName)
    }

    private func bundledFileURL(forFileName fileName: String) -> URL? {
        if let overriddenURL = bundledFileURLOverrides[fileName],
           fileManager.fileExists(atPath: overriddenURL.path) {
            return overriddenURL
        }

        guard allowBundledFileLookup else {
            return nil
        }

        let bundle = Bundle.main
        let baseName = fileName.replacingOccurrences(of: ".bin", with: "")
        let candidates = [
            bundle.url(forResource: baseName, withExtension: "bin", subdirectory: "Models"),
            bundle.url(forResource: baseName, withExtension: "bin")
        ]

        return candidates
            .compactMap { $0 }
            .first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func loadModelIfNeeded(at url: URL) throws {
        if loadedModelPath == url.path, context != nil {
            DebugLog.log("Model already loaded: \(DebugLog.displayPath(url))", category: "model")
            return
        }

        if let context {
            DebugLog.log("Freeing previous whisper context before loading \(DebugLog.displayPath(url))", category: "model")
            whisper_free(context)
            self.context = nil
        }

        var params = whisper_context_default_params()
        // The vendored macOS Metal backend has shown shutdown instability here.
        // Keep GPU opt-in until the embedded framework is updated to a fully stable build.
        let useGPU = Self.prefersGPUBackend(environment: environment)
        params.use_gpu = useGPU
        params.flash_attn = useGPU
        params.gpu_device = 0
        DebugLog.log("Loading whisper model from \(DebugLog.displayPath(url)) with GPU \(useGPU ? "enabled" : "disabled").", category: "model")

        let modelContext = url.path.withCString { pathPointer in
            whisper_init_from_file_with_params_no_state(pathPointer, params)
        }

        guard let modelContext else {
            DebugLog.log("whisper_init_from_file_with_params returned nil for \(DebugLog.displayPath(url))", category: "model")
            throw WhisperBridgeError.couldNotLoadModel
        }

        context = modelContext
        loadedModelPath = url.path
        DebugLog.log("Model loaded successfully from \(DebugLog.displayPath(url))", category: "model")
    }

    private func resolveLocalModelSelection() throws -> (variant: WhisperModelVariant, url: URL) {
        let modelVariants = Self.preferredModelVariants(environment: environment)

        if let bundledModel = firstBundledModel(from: modelVariants) {
            DebugLog.log("Using bundled model at \(DebugLog.displayPath(bundledModel.url))", category: "model")
            return bundledModel
        }

        if let overrideURL = localOverrideURL(forKey: Self.modelPathOverrideEnvironmentKey) {
            let overrideVariant = Self.variantForResolvedFile(url: overrideURL) ?? modelVariants[0]
            DebugLog.log("Using explicit local model override at \(DebugLog.displayPath(overrideURL))", category: "model")
            return (overrideVariant, overrideURL)
        }

        if let cachedModel = try firstCachedModel(from: modelVariants) {
            DebugLog.log("Using cached model at \(DebugLog.displayPath(cachedModel.url))", category: "model")
            return cachedModel
        }

        throw WhisperBridgeError.modelUnavailableLocally(fileName: modelVariants[0].fileName)
    }

    private func availableVADModelURL() throws -> URL? {
        if let bundledVADModelURL = bundledVADModelFileURL() {
            return bundledVADModelURL
        }

        if let overrideURL = localOverrideURL(forKey: Self.vadPathOverrideEnvironmentKey) {
            return overrideURL
        }

        let cachedVADModelURL = try cachedVADModelFileURL()
        guard fileManager.fileExists(atPath: cachedVADModelURL.path) else {
            return nil
        }

        return cachedVADModelURL
    }

    private func localOverrideURL(forKey key: String) -> URL? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let expandedPath = (rawValue as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: expandedPath) else {
            return nil
        }

        return URL(fileURLWithPath: expandedPath)
    }

    private static func variantForResolvedFile(url: URL) -> WhisperModelVariant? {
        let fileName = url.lastPathComponent
        guard fileName.hasPrefix("ggml-"),
              fileName.hasSuffix(".bin") else {
            return nil
        }

        let id = fileName
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
        guard !id.isEmpty else { return nil }

        return WhisperModelVariant(id: id)
    }

    private func firstBundledModel(from variants: [WhisperModelVariant]) -> (variant: WhisperModelVariant, url: URL)? {
        for variant in variants {
            if let bundledModelURL = bundledModelFileURL(for: variant) {
                return (variant, bundledModelURL)
            }
        }

        return nil
    }

    private func firstCachedModel(from variants: [WhisperModelVariant]) throws -> (variant: WhisperModelVariant, url: URL)? {
        for variant in variants {
            let cachedModelURL = try cachedModelFileURL(for: variant)
            if fileManager.fileExists(atPath: cachedModelURL.path) {
                return (variant, cachedModelURL)
            }
        }

        return nil
    }

    private static func prefersGPUBackend(environment: [String: String]) -> Bool {
        switch environment[useGPUEnvironmentKey]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func preferredModelVariants(environment: [String: String]) -> [WhisperModelVariant] {
        let preferredModels: [WhisperModelVariant]
        if let overrideModelID = validatedOverrideModelID(environment: environment) {
            preferredModels = [WhisperModelVariant(id: overrideModelID)]
        } else if prefersEnglishModel {
            preferredModels = [defaultEnglishPrimaryModel] + englishFallbackModels
        } else {
            preferredModels = [defaultMultilingualPrimaryModel] + multilingualFallbackModels
        }

        var uniqueModelIDs = Set<String>()
        return preferredModels.filter { uniqueModelIDs.insert($0.id).inserted }
    }

    private static func validatedOverrideModelID(environment: [String: String]) -> String? {
        guard let rawOverride = environment[modelOverrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOverride.isEmpty else {
            return nil
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard rawOverride.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            return nil
        }

        return rawOverride
    }

    private static var prefersEnglishModel: Bool {
        Locale.preferredLanguages.contains { languageCode in
            languageCode.lowercased().hasPrefix("en")
        }
    }
}
