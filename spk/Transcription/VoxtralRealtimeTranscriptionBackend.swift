import Foundation

private struct VoxtralRealtimeHelperCommand: Codable {
    let requestID: String
    let type: String
    let modelPath: String?
    let audioPath: String?
    let sessionID: String?
    let samplesBase64: String?

    static func loadModel(requestID: String, modelPath: String) -> Self {
        Self(
            requestID: requestID,
            type: "load_model",
            modelPath: modelPath,
            audioPath: nil,
            sessionID: nil,
            samplesBase64: nil
        )
    }

    static func transcribeFile(requestID: String, audioPath: String) -> Self {
        Self(
            requestID: requestID,
            type: "transcribe_file",
            modelPath: nil,
            audioPath: audioPath,
            sessionID: nil,
            samplesBase64: nil
        )
    }

    static func startSession(requestID: String, sessionID: String) -> Self {
        Self(
            requestID: requestID,
            type: "start_session",
            modelPath: nil,
            audioPath: nil,
            sessionID: sessionID,
            samplesBase64: nil
        )
    }

    static func appendAudio(requestID: String, sessionID: String, samplesBase64: String) -> Self {
        Self(
            requestID: requestID,
            type: "append_audio",
            modelPath: nil,
            audioPath: nil,
            sessionID: sessionID,
            samplesBase64: samplesBase64
        )
    }

    static func finishSession(requestID: String, sessionID: String) -> Self {
        Self(
            requestID: requestID,
            type: "finish_session",
            modelPath: nil,
            audioPath: nil,
            sessionID: sessionID,
            samplesBase64: nil
        )
    }

    static func cancelSession(requestID: String, sessionID: String) -> Self {
        Self(
            requestID: requestID,
            type: "cancel_session",
            modelPath: nil,
            audioPath: nil,
            sessionID: sessionID,
            samplesBase64: nil
        )
    }

    static func shutdown(requestID: String) -> Self {
        Self(
            requestID: requestID,
            type: "shutdown",
            modelPath: nil,
            audioPath: nil,
            sessionID: nil,
            samplesBase64: nil
        )
    }
}

private struct VoxtralRealtimeHelperResponse: Codable {
    let requestID: String?
    let type: String
    let message: String?
    let text: String?
    let modelDisplayName: String?
    let supportsStreamingPreview: Bool?
    let firstStreamingChunkSampleCount: Int?
    let streamingChunkSampleCount: Int?
    let sessionID: String?

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case type
        case message
        case text
        case modelDisplayName = "model_display_name"
        case supportsStreamingPreview = "supports_streaming_preview"
        case firstStreamingChunkSampleCount = "first_streaming_chunk_sample_count"
        case streamingChunkSampleCount = "streaming_chunk_sample_count"
        case sessionID = "session_id"
    }
}

struct VoxtralLiveSessionHandle: Sendable, Equatable {
    let sessionID: String
    let modelURL: URL
    let firstPreviewChunkSampleCount: Int
    let steadyStatePreviewChunkSampleCount: Int
}

enum VoxtralLiveInputSourceConfiguration: Equatable {
    case microphone
    case replayFile(URL)
}

actor VoxtralRealtimeHelperClient {
    private static let modelLoadTimeoutNanoseconds: UInt64 = 180_000_000_000
    private static let sessionStartTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let firstAppendTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let steadyStateAppendTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let finalizationTimeoutNanoseconds: UInt64 = 45_000_000_000
    private static let fileTranscriptionTimeoutNanoseconds: UInt64 = 90_000_000_000
    private static let progressBufferLimit = 16_384
    private static let defaultFirstStreamingChunkSampleCount = 3_840
    private static let defaultStreamingChunkSampleCount = 3_840

    private enum ProcessLaunchState {
        case alreadyRunning(UUID)
        case launched(UUID)

        var generation: UUID {
            switch self {
            case .alreadyRunning(let generation), .launched(let generation):
                return generation
            }
        }

        var launchedNewProcess: Bool {
            switch self {
            case .alreadyRunning:
                return false
            case .launched:
                return true
            }
        }
    }

    enum HelperError: LocalizedError {
        case missingHelper(String)
        case missingRuntime(String)
        case helperExited(String)
        case malformedResponse(String)
        case helperFailure(String)

        var errorDescription: String? {
            switch self {
            case .missingHelper(let message),
                 .missingRuntime(let message),
                 .helperExited(let message),
                 .malformedResponse(let message),
                 .helperFailure(let message):
                return message
            }
        }
    }

    struct PreparationResult: Sendable, Equatable {
        let modelDisplayName: String
        let supportsStreamingPreview: Bool
        let firstStreamingChunkSampleCount: Int
        let streamingChunkSampleCount: Int
    }

    struct PreparationProgress: Sendable, Equatable {
        let fraction: Double
        let detail: String
    }

    private let environment: [String: String]
    private let bundle: Bundle
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var pendingResponses: [String: CheckedContinuation<VoxtralRealtimeHelperResponse, Error>] = [:]
    private var pendingTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var stdoutFragment = Data()
    private var stderrBuffer = ""
    private var stderrFragment = Data()
    private var loadedModelPath: String?
    private var preparationResult: PreparationResult?
    private var preparedGeneration: UUID?
    private var streamingProbeModelPath: String?
    private var streamingProbeGeneration: UUID?
    private var latestPreparationProgress: PreparationProgress?
    private var processGeneration = UUID()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func prepare(modelURL: URL) async throws -> PreparationResult {
        let standardizedModelPath = modelURL.standardizedFileURL.path
        let processLaunchState = try await ensureProcessRunning()
        let currentGeneration = processLaunchState.generation

        if processLaunchState.launchedNewProcess {
            discardCachedPreparationIfNeeded(currentGeneration: currentGeneration)
        }

        if loadedModelPath == standardizedModelPath,
           let preparationResult,
           preparedGeneration == currentGeneration {
            return preparationResult
        }

        latestPreparationProgress = PreparationProgress(
            fraction: 0,
            detail: "Starting the local Voxtral runtime..."
        )
        DebugLog.log(
            "Sending Voxtral load_model request. model=\(modelURL.lastPathComponent) generation=\(currentGeneration.uuidString)",
            category: "transcription"
        )
        let response = try await send(
            .loadModel(
                requestID: UUID().uuidString,
                modelPath: standardizedModelPath
            ),
            timeoutNanoseconds: Self.modelLoadTimeoutNanoseconds,
            timeoutMessage: "Loading the local Voxtral model timed out.",
            shouldEnsureProcessRunning: false
        )
        guard response.type == "ready" else {
            throw HelperError.malformedResponse("The Voxtral helper returned an unexpected response while loading the model.")
        }
        DebugLog.log(
            "Received Voxtral ready response. model=\(modelURL.lastPathComponent) generation=\(currentGeneration.uuidString)",
            category: "transcription"
        )

        loadedModelPath = standardizedModelPath
        let preparationResult = PreparationResult(
            modelDisplayName: response.modelDisplayName ?? modelURL.lastPathComponent,
            supportsStreamingPreview: response.supportsStreamingPreview ?? false,
            firstStreamingChunkSampleCount: max(
                response.firstStreamingChunkSampleCount ?? Self.defaultFirstStreamingChunkSampleCount,
                1
            ),
            streamingChunkSampleCount: max(
                response.streamingChunkSampleCount ?? Self.defaultStreamingChunkSampleCount,
                1
            )
        )
        self.preparationResult = preparationResult
        preparedGeneration = currentProcessGeneration()
        streamingProbeModelPath = nil
        streamingProbeGeneration = nil
        latestPreparationProgress = nil
        DebugLog.log(
            "Prepared Voxtral helper state for model. model=\(modelURL.lastPathComponent) generation=\(currentGeneration.uuidString)",
            category: "transcription"
        )
        return preparationResult
    }

    func currentProcessGeneration() -> UUID? {
        guard process?.isRunning == true else {
            return nil
        }

        return processGeneration
    }

    func currentStreamingProbeGeneration() -> UUID? {
        guard process?.isRunning == true,
              streamingProbeGeneration == processGeneration
        else {
            return nil
        }

        return streamingProbeGeneration
    }

    func preparationProgress() -> PreparationProgress? {
        latestPreparationProgress
    }

    func transcribeAudioFile(at audioURL: URL, modelURL: URL) async throws -> String {
        _ = try await prepare(modelURL: modelURL)

        let response = try await send(
            .transcribeFile(
                requestID: UUID().uuidString,
                audioPath: audioURL.standardizedFileURL.path
            ),
            timeoutNanoseconds: Self.fileTranscriptionTimeoutNanoseconds,
            timeoutMessage: "Voxtral timed out while transcribing the prepared recording.",
            shouldEnsureProcessRunning: false
        )
        guard response.type == "final_transcript", let text = response.text else {
            throw HelperError.malformedResponse("The Voxtral helper did not return a final transcript.")
        }

        return text
    }

    func startStreamingSession(
        id sessionID: String,
        modelURL: URL,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        timeoutMessage: String = "The Voxtral helper timed out while starting a live session."
    ) async throws {
        _ = try await prepare(modelURL: modelURL)

        let response = try await send(
            .startSession(
                requestID: UUID().uuidString,
                sessionID: sessionID
            ),
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutMessage: timeoutMessage,
            shouldEnsureProcessRunning: false
        )
        guard response.type == "session_started" else {
            throw HelperError.malformedResponse("The Voxtral helper did not acknowledge the streaming session start.")
        }
    }

    func probeStreamingIngestion(modelURL: URL) async throws -> PreparationResult {
        let standardizedModelPath = modelURL.standardizedFileURL.path
        let preparationResult = try await prepare(modelURL: modelURL)
        DebugLog.log(
            "Continuing Voxtral live-ingestion probe after model preparation. model=\(modelURL.lastPathComponent)",
            category: "transcription"
        )

        guard preparationResult.supportsStreamingPreview else {
            return preparationResult
        }

        guard let currentGeneration = currentProcessGeneration() else {
            throw HelperError.helperExited("The Voxtral helper exited before live ingestion could be primed.")
        }

        if streamingProbeModelPath == standardizedModelPath,
           streamingProbeGeneration == currentGeneration {
            return preparationResult
        }

        let probeSessionID = UUID().uuidString
        DebugLog.log(
            "Starting Voxtral live-ingestion probe. model=\(modelURL.lastPathComponent) generation=\(currentGeneration.uuidString) session=\(probeSessionID)",
            category: "transcription"
        )

        do {
            DebugLog.log(
                "Sending Voxtral live-ingestion probe start_session. session=\(probeSessionID)",
                category: "transcription"
            )
            let startResponse = try await send(
                .startSession(
                    requestID: UUID().uuidString,
                    sessionID: probeSessionID
                ),
                timeoutNanoseconds: Self.sessionStartTimeoutNanoseconds,
                timeoutMessage: "The Voxtral helper timed out while priming live ingestion."
            )
            guard startResponse.type == "session_started" else {
                throw HelperError.malformedResponse("The Voxtral helper did not acknowledge the live-ingestion probe start.")
            }
            DebugLog.log(
                "Sending Voxtral live-ingestion probe append_audio. session=\(probeSessionID) sampleCount=\(preparationResult.firstStreamingChunkSampleCount)",
                category: "transcription"
            )
            _ = try await appendAudioChunk(
                Self.syntheticStreamingProbeSamples(sampleCount: preparationResult.firstStreamingChunkSampleCount),
                sessionID: probeSessionID,
                modelURL: modelURL,
                isFirstPreviewRequest: true
            )
            DebugLog.log(
                "Cancelling Voxtral live-ingestion probe session after first append. session=\(probeSessionID)",
                category: "transcription"
            )
            await cancelStreamingSession(id: probeSessionID)

            guard let probedGeneration = currentProcessGeneration() else {
                throw HelperError.helperExited("The Voxtral helper exited before live ingestion finished priming.")
            }

            streamingProbeModelPath = standardizedModelPath
            streamingProbeGeneration = probedGeneration
            DebugLog.log(
                "Completed Voxtral live-ingestion probe. model=\(modelURL.lastPathComponent) generation=\(probedGeneration.uuidString) session=\(probeSessionID)",
                category: "transcription"
            )
            return preparationResult
        } catch {
            DebugLog.log(
                "Voxtral live-ingestion probe failed. model=\(modelURL.lastPathComponent) generation=\(currentGeneration.uuidString) session=\(probeSessionID) error=\(error.localizedDescription)",
                category: "transcription"
            )
            streamingProbeModelPath = nil
            streamingProbeGeneration = nil
            await cancelStreamingSession(id: probeSessionID)
            throw error
        }
    }

    func appendAudioChunk(
        _ samples: [Float],
        sessionID: String,
        modelURL: URL,
        isFirstPreviewRequest: Bool
    ) async throws -> String {
        let response = try await send(
            .appendAudio(
                requestID: UUID().uuidString,
                sessionID: sessionID,
                samplesBase64: Self.encodePCM16(samples: samples)
            ),
            timeoutNanoseconds: isFirstPreviewRequest
                ? Self.firstAppendTimeoutNanoseconds
                : Self.steadyStateAppendTimeoutNanoseconds,
            timeoutMessage: isFirstPreviewRequest
                ? "The Voxtral helper timed out while generating the first live preview update."
                : "The Voxtral helper timed out while generating a live preview update.",
            shouldEnsureProcessRunning: false
        )
        guard response.type == "preview_update" else {
            throw HelperError.malformedResponse("The Voxtral helper did not return a preview update.")
        }

        return response.text ?? ""
    }

    func finishStreamingSession(id sessionID: String, modelURL: URL) async throws -> String {
        let response = try await send(
            .finishSession(
                requestID: UUID().uuidString,
                sessionID: sessionID
            ),
            timeoutNanoseconds: Self.finalizationTimeoutNanoseconds,
            timeoutMessage: "The Voxtral helper timed out while finalizing the live transcript.",
            shouldEnsureProcessRunning: false
        )
        guard response.type == "final_transcript" else {
            throw HelperError.malformedResponse("The Voxtral helper did not return a final transcript for the live session.")
        }

        return response.text ?? ""
    }

    func cancelStreamingSession(id sessionID: String) async {
        guard process != nil else {
            return
        }

        _ = try? await send(
            .cancelSession(
                requestID: UUID().uuidString,
                sessionID: sessionID
            ),
            timeoutNanoseconds: 5_000_000_000,
            timeoutMessage: "The Voxtral helper timed out while cancelling the live session.",
            shouldEnsureProcessRunning: false
        )
    }

    func shutdown() async {
        let generation = processGeneration
        if process != nil {
            _ = try? await send(
                .shutdown(requestID: UUID().uuidString),
                timeoutNanoseconds: 5_000_000_000,
                timeoutMessage: "The Voxtral helper timed out while shutting down.",
                shouldEnsureProcessRunning: false
            )
        }
        await tearDownProcess(reason: nil, generation: generation, expectedShutdown: true)
    }

    private func ensureProcessRunning() async throws -> ProcessLaunchState {
        if process?.isRunning == true {
            return .alreadyRunning(processGeneration)
        }

        let helperResolution = VoxtralRealtimeModelLocator.resolveHelper(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager
        )

        let helperURL: URL
        switch helperResolution {
        case .ready(let resolvedURL):
            helperURL = resolvedURL
        case .invalidEnvironmentPath(let path):
            throw HelperError.missingHelper("spk could not find the Voxtral helper at \(path).")
        case .missingHelper:
            throw HelperError.missingHelper("spk could not find the bundled Voxtral helper script.")
        }

        let process = Process()
        switch VoxtralRealtimeModelLocator.resolvePython(
            environment: environment,
            fileManager: fileManager
        ) {
        case .ready(let pythonURL):
            process.executableURL = pythonURL
            process.arguments = [helperURL.path]
        case .invalidEnvironmentPath(let path):
            throw HelperError.missingRuntime("spk could not find the Voxtral Python runtime at \(path).")
        case .missingPreferredRuntime:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", helperURL.path]
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let generation = UUID()

        process.terminationHandler = { [weak self] process in
            Task {
                await self?.handleProcessTermination(process, generation: generation)
            }
        }

        try process.run()

        self.process = process
        processGeneration = generation
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutFragment.removeAll(keepingCapacity: false)
        self.stderrBuffer = ""
        self.stderrFragment.removeAll(keepingCapacity: false)
        self.latestPreparationProgress = nil
        DebugLog.log(
            "Started Voxtral helper generation=\(generation.uuidString)",
            category: "transcription"
        )
        self.readerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard let self else {
                    return
                }
                if data.isEmpty {
                    await self.finalizeStdoutStream(generation: generation)
                    return
                }

                await self.consumeStdoutChunk(data, generation: generation)
            }
        }

        self.stderrTask = Task { [weak self] in
            await self?.consumeStderr(stderrPipe.fileHandleForReading, generation: generation)
        }

        return .launched(generation)
    }

    private func send(
        _ command: VoxtralRealtimeHelperCommand,
        timeoutNanoseconds: UInt64? = nil,
        timeoutMessage: String? = nil,
        shouldEnsureProcessRunning: Bool = true
    ) async throws -> VoxtralRealtimeHelperResponse {
        if shouldEnsureProcessRunning {
            _ = try await ensureProcessRunning()
        }

        let encodedCommand = try encoder.encode(command)
        guard let stdinHandle else {
            throw HelperError.helperExited("The Voxtral helper exited before it could accept a request.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[command.requestID] = continuation
            if let timeoutNanoseconds,
               let timeoutMessage {
                pendingTimeoutTasks[command.requestID] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.failPendingResponse(
                        requestID: command.requestID,
                        error: HelperError.helperFailure(timeoutMessage)
                    )
                }
            }
            if command.type != "append_audio" {
                DebugLog.log(
                    "Writing Voxtral helper request. type=\(command.type) requestID=\(command.requestID)",
                    category: "transcription"
                )
            }
            do {
                try stdinHandle.write(contentsOf: encodedCommand + Data([0x0A]))
            } catch {
                let storedContinuation = pendingResponses.removeValue(forKey: command.requestID)
                pendingTimeoutTasks.removeValue(forKey: command.requestID)?.cancel()
                storedContinuation?.resume(throwing: error)
            }
        }
    }

    private func failPendingResponse(requestID: String, error: Error) {
        pendingTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }

        continuation.resume(throwing: error)
    }

    private func consumeStdoutChunk(_ data: Data, generation: UUID) async {
        do {
            for byte in data {
                if byte == 0x0A || byte == 0x0D {
                    try flushStdoutFragment()
                    continue
                }

                stdoutFragment.append(byte)
            }
        } catch {
            await tearDownProcess(
                reason: "The Voxtral helper stopped responding. \(error.localizedDescription)",
                generation: generation
            )
        }
    }

    private func finalizeStdoutStream(generation: UUID) async {
        do {
            try flushStdoutFragment()
        } catch {
            await tearDownProcess(
                reason: "The Voxtral helper stopped responding. \(error.localizedDescription)",
                generation: generation
            )
        }
    }

    private func consumeStderr(_ handle: FileHandle, generation: UUID) async {
        do {
            for try await byte in handle.bytes {
                if byte == 0x0A || byte == 0x0D {
                    flushStderrFragment()
                    continue
                }

                stderrFragment.append(byte)
            }

            flushStderrFragment()
        } catch {
            if Self.isExpectedShutdownCancellation(error) {
                DebugLog.log(
                    "Ignoring Voxtral helper stderr cancellation during shutdown. generation=\(generation.uuidString)",
                    category: "transcription"
                )
            }
            flushStderrFragment()
        }
    }

    private func handleProcessTermination(_ process: Process, generation: UUID) async {
        let reason: String
        if process.terminationStatus == 0 {
            reason = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let stderrSummary = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = stderrSummary.isEmpty
                ? "The Voxtral helper exited with status \(process.terminationStatus)."
                : stderrSummary
        }

        await tearDownProcess(reason: reason.isEmpty ? nil : reason, generation: generation)
    }

    private func tearDownProcess(
        reason: String?,
        generation: UUID,
        expectedShutdown: Bool = false
    ) async {
        guard generation == processGeneration else {
            DebugLog.log(
                "Ignoring stale Voxtral helper teardown. staleGeneration=\(generation.uuidString) currentGeneration=\(processGeneration.uuidString)",
                category: "transcription"
            )
            return
        }

        process?.terminationHandler = nil
        process = nil
        processGeneration = UUID()
        try? stdinHandle?.close()
        stdinHandle = nil
        let priorReaderTask = readerTask
        readerTask = nil
        priorReaderTask?.cancel()
        let priorStderrTask = stderrTask
        stderrTask = nil
        priorStderrTask?.cancel()
        loadedModelPath = nil
        preparationResult = nil
        preparedGeneration = nil
        streamingProbeModelPath = nil
        streamingProbeGeneration = nil
        latestPreparationProgress = nil
        stdoutFragment.removeAll(keepingCapacity: false)
        stderrFragment.removeAll(keepingCapacity: false)

        for timeoutTask in pendingTimeoutTasks.values {
            timeoutTask.cancel()
        }
        pendingTimeoutTasks.removeAll()

        let error = expectedShutdown ? nil : reason.map { HelperError.helperExited($0) }
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error ?? HelperError.helperExited("The Voxtral helper exited unexpectedly."))
        }

        DebugLog.log(
            expectedShutdown
                ? "Stopped Voxtral helper generation=\(generation.uuidString)"
                : "Tore down Voxtral helper generation=\(generation.uuidString) reason=\(reason ?? "unknown")",
            category: "transcription"
        )
    }

    private func discardCachedPreparationIfNeeded(currentGeneration: UUID) {
        guard loadedModelPath != nil
            || preparationResult != nil
            || preparedGeneration != nil
            || streamingProbeModelPath != nil
            || streamingProbeGeneration != nil
        else {
            return
        }

        DebugLog.log(
            "Discarding cached Voxtral helper readiness after helper generation changed. previousModelGeneration=\(preparedGeneration?.uuidString ?? "none") previousLiveIngestionGeneration=\(streamingProbeGeneration?.uuidString ?? "none") currentGeneration=\(currentGeneration.uuidString)",
            category: "transcription"
        )
        loadedModelPath = nil
        preparationResult = nil
        preparedGeneration = nil
        streamingProbeModelPath = nil
        streamingProbeGeneration = nil
    }

    private static func encodePCM16(samples: [Float]) -> String {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clippedSample = min(max(sample, -1), 1)
            var intSample = Int16(clippedSample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { bytes in
                data.append(bytes.bindMemory(to: UInt8.self))
            }
        }

        return data.base64EncodedString()
    }

    private static func syntheticStreamingProbeSamples(sampleCount: Int) -> [Float] {
        Array(repeating: 0.04, count: max(sampleCount, 1))
    }

    private static func isExpectedShutdownCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        return error.localizedDescription.contains("CancellationError")
    }

    private func flushStderrFragment() {
        guard !stderrFragment.isEmpty,
              let text = String(data: stderrFragment, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            stderrFragment.removeAll(keepingCapacity: true)
            return
        }

        stderrFragment.removeAll(keepingCapacity: true)
        appendToStderrBuffer(text)
        if let progress = Self.parsePreparationProgress(from: text) {
            latestPreparationProgress = progress
        }
    }

    private func flushStdoutFragment() throws {
        guard !stdoutFragment.isEmpty else {
            return
        }

        let data = stdoutFragment
        stdoutFragment.removeAll(keepingCapacity: true)
        let response = try decoder.decode(VoxtralRealtimeHelperResponse.self, from: data)
        if response.type != "preview_update" {
            DebugLog.log(
                "Received Voxtral helper response. type=\(response.type) requestID=\(response.requestID ?? "none")",
                category: "transcription"
            )
        }
        if response.type == "error" {
            let message = response.message ?? "The Voxtral helper returned an unknown error."
            if let requestID = response.requestID,
               let continuation = pendingResponses.removeValue(forKey: requestID) {
                pendingTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                DebugLog.log(
                    "Matched Voxtral helper error response to request. requestID=\(requestID)",
                    category: "transcription"
                )
                continuation.resume(throwing: HelperError.helperFailure(message))
            } else if let requestID = response.requestID {
                DebugLog.log(
                    "Received Voxtral helper error response without a pending request. requestID=\(requestID)",
                    category: "transcription"
                )
            }
            return
        }

        if let requestID = response.requestID {
            if let continuation = pendingResponses.removeValue(forKey: requestID) {
                pendingTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                DebugLog.log(
                    "Matched Voxtral helper response to request. type=\(response.type) requestID=\(requestID)",
                    category: "transcription"
                )
                continuation.resume(returning: response)
            } else {
                DebugLog.log(
                    "Received Voxtral helper response without a pending request. type=\(response.type) requestID=\(requestID)",
                    category: "transcription"
                )
            }
        }
    }

    private func appendToStderrBuffer(_ text: String) {
        if stderrBuffer.isEmpty {
            stderrBuffer = text
        } else {
            stderrBuffer += "\n" + text
        }

        if stderrBuffer.count > Self.progressBufferLimit {
            stderrBuffer = String(stderrBuffer.suffix(Self.progressBufferLimit))
        }
    }

    private static func parsePreparationProgress(from line: String) -> PreparationProgress? {
        guard line.contains("Loading weights:"),
              let match = line.range(
                of: #"Loading weights:\s+(\d+)%"#,
                options: .regularExpression
              )
        else {
            return nil
        }

        let matchedText = String(line[match])
        guard let percentRange = matchedText.range(
            of: #"\d+"#,
            options: .regularExpression
        ), let percent = Int(matchedText[percentRange])
        else {
            return nil
        }

        let clampedPercent = min(max(percent, 0), 100)
        return PreparationProgress(
            fraction: Double(clampedPercent) / 100,
            detail: "Loading \(VoxtralRealtimeModelLocator.defaultModelDirectoryName) weights... \(clampedPercent)%"
        )
    }
}

actor VoxtralRealtimeTranscriptionBackend: TranscriptionBackend {
    static let debugLiveAudioFileEnvironmentKey = "SPK_DEBUG_VOXTRAL_LIVE_AUDIO_FILE"
    private static let liveInputReadyTimeoutNanoseconds: UInt64 = 1_500_000_000
    private static let minimumHealthyLiveInputSampleCount = 4_096
    private static let recordingSessionStartTimeoutNanoseconds: UInt64 = 10_000_000_000

    enum BackendError: LocalizedError {
        case unsupportedHardware
        case invalidModelPath(String)
        case missingModel
        case helperUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedHardware:
                return "Voxtral Realtime currently requires Apple Silicon."
            case .invalidModelPath(let path):
                return "spk could not find a Voxtral Realtime model folder at \(path)."
            case .missingModel:
                return "spk could not find a local Voxtral Realtime model. Choose one in Settings or install it under Application Support."
            case .helperUnavailable(let message):
                return message
            }
        }
    }

    let selection: TranscriptionBackendSelection = .voxtralRealtime

    private let helperClient: VoxtralRealtimeHelperClient
    private let streamingCoordinator: VoxtralRealtimeStreamingCoordinator
    private let settingsSnapshotProvider: @Sendable () async -> VoxtralRealtimeSettingsSnapshot
    private let environment: [String: String]
    private let fileManager: FileManager
    private let bundle: Bundle
    private let transcribeAudioFileHandler: @Sendable (URL, URL) async throws -> String
    private let liveInputSourceFactory: (VoxtralLiveInputSourceConfiguration) throws -> any VoxtralLiveInputSource

    private var preparedModel: VoxtralRealtimeResolvedModel?
    private var liveReadyHelperGeneration: UUID?
    private var lastStreamingStopOutcome: VoxtralStreamingStopOutcome?
    private var activeLiveSession: VoxtralLiveSessionHandle?
    private var activeInputSource: (any VoxtralLiveInputSource)?
    private var pendingStartTask: Task<VoxtralLiveSessionHandle, Error>?
    private var isStartInFlight = false
    private var pendingStartCancellationRequested = false
    private var pendingStartStatusMessageState: String?
    private var livePreviewRuntimeState: LivePreviewRuntimeState = .inactive
    private var preparationProgressState: TranscriptionPreparationProgress?
    private var preparationStage: TranscriptionPreparationStage = .locatingModel
    private var lastLoggedPreparationStage: TranscriptionPreparationStage?
    private var backgroundRecoveryTask: Task<Bool, Never>?
    private var backgroundRecoveryTaskID: UUID?

    init(
        settingsSnapshotProvider: @escaping @Sendable () async -> VoxtralRealtimeSettingsSnapshot,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        helperClient: VoxtralRealtimeHelperClient? = nil,
        streamingCoordinator: VoxtralRealtimeStreamingCoordinator? = nil,
        preparedModel: VoxtralRealtimeResolvedModel? = nil,
        initialStreamingStopOutcome: VoxtralStreamingStopOutcome? = nil,
        liveInputSourceFactory: ((VoxtralLiveInputSourceConfiguration) throws -> any VoxtralLiveInputSource)? = nil,
        transcribeAudioFileHandler: (@Sendable (URL, URL) async throws -> String)? = nil
    ) {
        let resolvedHelperClient = helperClient ?? VoxtralRealtimeHelperClient(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager
        )
        let resolvedStreamingCoordinator = streamingCoordinator ?? VoxtralRealtimeStreamingCoordinator(
            helperClient: resolvedHelperClient,
            settingsSnapshotProvider: settingsSnapshotProvider,
            environment: environment,
            fileManager: fileManager
        )
        self.helperClient = resolvedHelperClient
        self.streamingCoordinator = resolvedStreamingCoordinator
        self.settingsSnapshotProvider = settingsSnapshotProvider
        self.environment = environment
        self.fileManager = fileManager
        self.bundle = bundle
        self.preparedModel = preparedModel
        self.lastStreamingStopOutcome = initialStreamingStopOutcome
        self.liveInputSourceFactory = liveInputSourceFactory ?? { configuration in
            switch configuration {
            case .microphone:
                return try VoxtralMicrophoneInputSource(fileManager: fileManager)
            case .replayFile(let fileURL):
                return try VoxtralReplayFileInputSource(inputURL: fileURL, fileManager: fileManager)
            }
        }
        self.transcribeAudioFileHandler = transcribeAudioFileHandler ?? { audioURL, modelURL in
            let freshHelperClient = VoxtralRealtimeHelperClient(
                environment: environment,
                bundle: bundle,
                fileManager: .default
            )
            defer {
                Task {
                    await freshHelperClient.shutdown()
                }
            }
            return try await freshHelperClient.transcribeAudioFile(at: audioURL, modelURL: modelURL)
        }
    }

    func prepare() async throws -> TranscriptionPreparation {
        try await prepare(cancellingBackgroundRecoveryTask: true)
    }

    private func prepare(cancellingBackgroundRecoveryTask: Bool) async throws -> TranscriptionPreparation {
        if cancellingBackgroundRecoveryTask {
            backgroundRecoveryTask?.cancel()
            backgroundRecoveryTask = nil
            backgroundRecoveryTaskID = nil
        }
        updatePreparationProgress(
            stage: .locatingModel,
            fraction: 0.08,
            detail: "Locating the local Voxtral Realtime model..."
        )
        let resolvedModel = try await resolveModel()
        preparedModel = resolvedModel
        liveReadyHelperGeneration = nil

        let helperURL = try resolvedHelperURL()
        let pythonURL = try resolvedPythonURL()
        let appBuildVersion = currentAppBuildVersion()
        switch VoxtralReadinessManifestStore.validateCurrent(
            appBuildVersion: appBuildVersion,
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: resolvedModel.url,
            fileManager: fileManager
        ) {
        case .valid:
            DebugLog.log(
                "Validated Voxtral install-time readiness manifest. model=\(resolvedModel.displayName)",
                category: "transcription"
            )
        case .missing:
            DebugLog.log(
                "Voxtral readiness manifest is missing. Running full local preparation. model=\(resolvedModel.displayName)",
                category: "transcription"
            )
        case .invalid(let reason):
            DebugLog.log(
                "Voxtral readiness manifest is stale. reason=\(reason) model=\(resolvedModel.displayName)",
                category: "transcription"
            )
        }

        updatePreparationProgress(
            stage: .launchingHelper,
            fraction: 0.16,
            detail: "Starting the local Voxtral runtime..."
        )

        updatePreparationProgress(
            stage: .loadingModel,
            fraction: 0.52,
            detail: "Loading Voxtral Realtime model weights..."
        )
        let helperPreparation = try await helperClient.prepare(modelURL: resolvedModel.url)
        guard helperPreparation.supportsStreamingPreview else {
            throw BackendError.helperUnavailable(
                "The local Voxtral helper does not advertise live preview support yet."
            )
        }
        updatePreparationProgress(
            stage: .warmingStreaming,
            fraction: 0.82,
            detail: "Preparing Voxtral live ingestion..."
        )
        DebugLog.log(
            "Starting Voxtral background live-ingestion probe. model=\(resolvedModel.displayName)",
            category: "transcription"
        )
        _ = try await helperClient.probeStreamingIngestion(modelURL: resolvedModel.url)
        DebugLog.log(
            "Completed Voxtral background live-ingestion probe. model=\(resolvedModel.displayName)",
            category: "transcription"
        )
        guard let liveReadyHelperGeneration = await helperClient.currentStreamingProbeGeneration() else {
            throw BackendError.helperUnavailable(
                "The Voxtral helper did not stay ready after live ingestion was primed."
            )
        }
        self.liveReadyHelperGeneration = liveReadyHelperGeneration
        updatePreparationProgress(
            stage: .ready,
            fraction: 1,
            detail: "Voxtral Realtime live preview is ready locally."
        )
        do {
            _ = try VoxtralReadinessManifestStore.writeCurrent(
                appBuildVersion: appBuildVersion,
                helperURL: helperURL,
                pythonURL: pythonURL,
                modelURL: resolvedModel.url,
                fileManager: fileManager
            )
            DebugLog.log(
                "Persisted Voxtral readiness manifest at \(DebugLog.displayPath(VoxtralReadinessManifestStore.manifestURL(fileManager: fileManager))).",
                category: "transcription"
            )
        } catch {
            DebugLog.log(
                "Failed to persist the Voxtral readiness manifest: \(error)",
                category: "transcription"
            )
        }

        return TranscriptionPreparation(
            resolvedModelURL: resolvedModel.url,
            readyDisplayName: resolvedModel.displayName
        )
    }

    func preparationProgress() async -> TranscriptionPreparationProgress? {
        if preparationStage == .loadingModel,
           let progress = await helperClient.preparationProgress() {
            return TranscriptionPreparationProgress(
                stage: .loadingModel,
                fraction: 0.18 + (min(max(progress.fraction, 0), 1) * 0.56),
                detail: progress.detail
            )
        }

        return preparationProgressState
    }

    func invalidatePreparation() async {
        pendingStartTask?.cancel()
        pendingStartTask = nil
        isStartInFlight = false
        pendingStartCancellationRequested = false
        pendingStartStatusMessageState = nil
        livePreviewRuntimeState = .inactive
        if let activeInputSource {
            _ = await activeInputSource.stop()
            self.activeInputSource = nil
        }
        preparedModel = nil
        liveReadyHelperGeneration = nil
        preparationStage = .locatingModel
        preparationProgressState = nil
        lastLoggedPreparationStage = nil
        backgroundRecoveryTask?.cancel()
        backgroundRecoveryTask = nil
        backgroundRecoveryTaskID = nil
        await streamingCoordinator.clearPreparedLiveSession()
        await helperClient.shutdown()
    }

    func modelDirectoryURL() async throws -> URL {
        if let preparedModel {
            return preparedModel.url
        }

        switch await currentModelResolution() {
        case .ready(let resolvedModel):
            return resolvedModel.url
        case .invalidEnvironmentPath(let path),
             .invalidCustomPath(let path):
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        case .missingModel, .unsupportedHardware:
            return VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager)
        }
    }

    func startRecording(preferredInputDeviceID: String?) async throws -> RecordingStartResult {
        lastStreamingStopOutcome = nil
        activeLiveSession = nil
        activeInputSource = nil
        pendingStartTask?.cancel()
        pendingStartTask = nil
        isStartInFlight = true
        pendingStartCancellationRequested = false
        pendingStartStatusMessageState = nil
        livePreviewRuntimeState = .inactive
        var hasAttemptedInlineRecovery = false

        while true {
            do {
                let hadBackgroundRecoveryTask = backgroundRecoveryTask != nil
                let backgroundRecoverySucceeded = await waitForBackgroundRecoveryIfNeeded()
                if hadBackgroundRecoveryTask, !backgroundRecoverySucceeded {
                    if hasAttemptedInlineRecovery {
                        throw BackendError.helperUnavailable(
                            "Voxtral is still preparing locally. Wait a moment and try again."
                        )
                    }
                    hasAttemptedInlineRecovery = true
                    try await rebuildPreparedStateSynchronously(
                        reason: "background Voxtral recovery did not complete cleanly",
                        statusMessage: "Restarting Voxtral live ingestion..."
                    )
                    continue
                }

                if preparedModel == nil {
                    if hasAttemptedInlineRecovery {
                        throw BackendError.helperUnavailable(
                            "Voxtral is still preparing locally. Wait a moment and try again."
                        )
                    }
                    hasAttemptedInlineRecovery = true
                    try await rebuildPreparedStateSynchronously(
                        reason: "Voxtral was not fully prepared when recording started",
                        statusMessage: "Preparing Voxtral live ingestion..."
                    )
                    continue
                }

                guard let liveReadyHelperGeneration,
                      let currentHelperGeneration = await helperClient.currentProcessGeneration(),
                      liveReadyHelperGeneration == currentHelperGeneration
                else {
                    DebugLog.log(
                        "Invalidating Voxtral readiness because the current helper generation has not passed the live-ingestion probe. expectedGeneration=\(liveReadyHelperGeneration?.uuidString ?? "none") currentGeneration=\((await helperClient.currentProcessGeneration())?.uuidString ?? "none")",
                        category: "transcription"
                    )
                    self.liveReadyHelperGeneration = nil
                    if hasAttemptedInlineRecovery {
                        scheduleBackgroundRecovery(reason: "the Voxtral helper restarted before live ingestion was ready")
                        throw BackendError.helperUnavailable(
                            "Voxtral is restarting locally. Wait a moment and try again."
                        )
                    }
                    hasAttemptedInlineRecovery = true
                    try await rebuildPreparedStateSynchronously(
                        reason: "the Voxtral helper restarted before live ingestion was ready",
                        statusMessage: "Restarting Voxtral live ingestion..."
                    )
                    continue
                }

                if pendingStartCancellationRequested {
                    pendingStartCancellationRequested = false
                    throw CancellationError()
                }

                pendingStartStatusMessageState = hasAttemptedInlineRecovery
                    ? "Restarting Voxtral live ingestion..."
                    : "Starting Voxtral live session..."
                let liveSession = try await createLiveSessionForRecording()
                activeLiveSession = liveSession

                let inputSourceConfiguration = try Self.resolveLiveInputSourceConfiguration(
                    environment: environment,
                    fileManager: fileManager
                )
                let sourceStartResult = try await startLiveInputSource(
                    configuration: inputSourceConfiguration,
                    preferredInputDeviceID: preferredInputDeviceID,
                    liveSession: liveSession
                )

                _ = sourceStartResult.inputSource
                if hasAttemptedInlineRecovery {
                    DebugLog.log(
                        "Completed Voxtral recording start after waiting through inline live-ingestion recovery.",
                        category: "transcription"
                    )
                }
                livePreviewRuntimeState = .active
                isStartInFlight = false
                pendingStartStatusMessageState = nil
                return RecordingStartResult(
                    livePreviewState: .active,
                    inputStatusMessage: sourceStartResult.inputStatusMessage
                )
            } catch is CancellationError {
                pendingStartTask = nil
                isStartInFlight = false
                pendingStartCancellationRequested = false
                pendingStartStatusMessageState = nil
                livePreviewRuntimeState = .inactive
                if let activeInputSource {
                    _ = await activeInputSource.stop()
                    self.activeInputSource = nil
                }
                if let activeLiveSession {
                    await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
                    self.activeLiveSession = nil
                }
                await streamingCoordinator.clearPreparedLiveSession()
                throw CancellationError()
            } catch {
                pendingStartTask = nil
                isStartInFlight = false
                pendingStartCancellationRequested = false
                livePreviewRuntimeState = .inactive
                if let activeInputSource {
                    _ = await activeInputSource.stop()
                    self.activeInputSource = nil
                }
                if let activeLiveSession {
                    await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
                    self.activeLiveSession = nil
                }
                if !hasAttemptedInlineRecovery,
                   shouldRebuildPreparedStateAfterStartFailure(error) {
                    hasAttemptedInlineRecovery = true
                    do {
                        try await rebuildPreparedStateSynchronously(
                            reason: backgroundRecoveryReason(afterStartFailure: error),
                            statusMessage: "Restarting Voxtral live ingestion..."
                        )
                        continue
                    } catch {
                        DebugLog.log(
                            "Immediate Voxtral recovery before retrying recording failed: \(error)",
                            category: "transcription"
                        )
                    }
                }
                pendingStartStatusMessageState = nil
                if shouldRebuildPreparedStateAfterStartFailure(error) {
                    liveReadyHelperGeneration = nil
                    scheduleBackgroundRecovery(reason: backgroundRecoveryReason(afterStartFailure: error))
                }
                await streamingCoordinator.clearPreparedLiveSession()
                throw error
            }
        }
    }

    func cancelPendingRecordingStart() async {
        guard isStartInFlight else {
            return
        }

        pendingStartCancellationRequested = true
        isStartInFlight = false
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingStartStatusMessageState = nil
        livePreviewRuntimeState = .inactive
        if let activeInputSource {
            _ = await activeInputSource.stop()
            self.activeInputSource = nil
        }
        if let activeLiveSession {
            await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
            self.activeLiveSession = nil
        }
        await streamingCoordinator.clearPreparedLiveSession()
        DebugLog.log("Cancelled pending Voxtral live-session startup before recording began.", category: "transcription")
    }

    func stopRecording() async -> RecordingStopResult {
        livePreviewRuntimeState = .inactive
        isStartInFlight = false
        pendingStartCancellationRequested = false
        pendingStartTask = nil
        pendingStartStatusMessageState = nil
        let hadActiveLiveSession = activeLiveSession != nil
        let activeInputSource = self.activeInputSource
        self.activeInputSource = nil
        let recordingURL = await activeInputSource?.stop()
        if let activeInputSource {
            let emittedSamples = await activeInputSource.emittedSampleCount()
            DebugLog.log(
                "Stopped Voxtral live input source kind=\(activeInputSource.kindDescription) emittedSamples=\(emittedSamples) recording=\(recordingURL.map(DebugLog.displayPath) ?? "none")",
                category: "transcription"
            )
        }
        let stopResult = await streamingCoordinator.stop(recordingURL: recordingURL)
            ?? RecordingStopResult(recordingURL: recordingURL)
        if stopResult.recordingURL == nil, stopResult.bufferedSamples == nil {
            DebugLog.log(
                "Voxtral stop returned no recording artifact. This can happen if stop was requested more than once for the same session.",
                category: "transcription"
            )
        }
        lastStreamingStopOutcome = await streamingCoordinator.consumeStopOutcome()
        if !hadActiveLiveSession {
            lastStreamingStopOutcome = nil
        }
        activeLiveSession = nil
        if shouldRebuildPreparedState(stopOutcome: lastStreamingStopOutcome) {
            scheduleBackgroundRecovery(
                reason: backgroundRecoveryReason(stopOutcome: lastStreamingStopOutcome)
            )
        }
        return stopResult
    }

    func pendingRecordingStartStatusMessage() async -> String? {
        if let pendingStartStatusMessageState {
            return pendingStartStatusMessageState
        }

        guard isStartInFlight, let activeInputSource else {
            return nil
        }

        return await activeInputSource.healthState().statusMessage
    }

    func currentLivePreviewRuntimeState() async -> LivePreviewRuntimeState {
        if case .active = livePreviewRuntimeState,
           let runtimeReason = await streamingCoordinator.unavailableReason() {
            livePreviewRuntimeState = .unavailable(runtimeReason)
        }

        return livePreviewRuntimeState
    }

    func normalizedInputLevel() async -> Float {
        if let activeInputSource {
            return await activeInputSource.normalizedInputLevel()
        }

        return 0
    }

    func isLivePreviewRequested() async -> Bool {
        true
    }

    func latestPreviewSnapshot() async -> StreamingPreviewSnapshot? {
        await streamingCoordinator.previewSnapshot()
    }

    func livePreviewUnavailableReason() async -> String? {
        if let runtimeReason = livePreviewRuntimeState.unavailableReason {
            return runtimeReason
        }
        if let runtimeReason = await streamingCoordinator.unavailableReason() {
            return runtimeReason
        }

        switch await currentModelResolution() {
        case .unsupportedHardware:
            return BackendError.unsupportedHardware.localizedDescription
        case .invalidEnvironmentPath(let path),
             .invalidCustomPath(let path):
            return BackendError.invalidModelPath(path).localizedDescription
        case .missingModel:
            return BackendError.missingModel.localizedDescription
        case .ready:
            switch VoxtralRealtimeModelLocator.resolveHelper(
                environment: environment,
                bundle: bundle,
                fileManager: fileManager
            ) {
            case .ready:
                switch VoxtralRealtimeModelLocator.resolvePython(
                    environment: environment,
                    fileManager: fileManager
                ) {
                case .ready, .missingPreferredRuntime:
                    return "The local Voxtral helper is installed, but live preview could not start. spk will keep recording locally and still use Voxtral for the final transcript after you stop."
                case .invalidEnvironmentPath(let path):
                    return BackendError.helperUnavailable("spk could not find the Voxtral Python runtime at \(path).").localizedDescription
                }
            case .invalidEnvironmentPath(let path):
                return BackendError.helperUnavailable("spk could not find the Voxtral helper at \(path).").localizedDescription
            case .missingHelper:
                return BackendError.helperUnavailable("spk could not find the bundled Voxtral helper script.").localizedDescription
            }
        }
    }

    private struct LiveInputSourceStartResult: Sendable {
        let inputSource: any VoxtralLiveInputSource
        let inputStatusMessage: String?
    }

    private enum LiveInputSourceReadiness: Sendable {
        case active
        case timedOut(VoxtralLiveInputSourceHealth)
    }

    func transcribePreparedRecording(
        _ recording: PreparedRecording,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let stopOutcome = lastStreamingStopOutcome
        lastStreamingStopOutcome = nil

        if let frozenTranscript = stopOutcome?.bestAvailableTranscript,
           !frozenTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DebugLog.log(
                "Using frozen Voxtral live transcript from stop. length=\(frozenTranscript.count)",
                category: "transcription"
            )
            return frozenTranscript
        }

        if let stopOutcome {
            if let failureReason = stopOutcome.failureReason, !failureReason.isEmpty {
                DebugLog.log(
                    "Voxtral stop completed without a usable live transcript after a live-session failure. Skipping post-stop WAV retry. reason=\(failureReason)",
                    category: "transcription"
                )
            } else if stopOutcome.wasCleanUserStop {
                DebugLog.log(
                    "Voxtral stop completed without a usable live transcript. Skipping post-stop WAV retry because stop freezes the current live text.",
                    category: "transcription"
                )
            } else {
                DebugLog.log(
                    "Voxtral stop did not produce a usable live transcript. Skipping post-stop WAV retry.",
                    category: "transcription"
                )
            }
            return ""
        }

        let resolvedModel: VoxtralRealtimeResolvedModel
        if let preparedModel {
            resolvedModel = preparedModel
        } else {
            resolvedModel = try await resolveModel()
        }

        guard let sourceRecordingURL = recording.sourceRecordingURL else {
            throw BackendError.helperUnavailable(
                "Voxtral needs the original recorded WAV file to transcribe this recording."
            )
        }

        await statusHandler("Transcribing with Voxtral...")
        DebugLog.log(
            "Transcribing the recorded WAV with Voxtral. file=\(DebugLog.displayPath(sourceRecordingURL))",
            category: "transcription"
        )
        let transcript = try await transcribeAudioFileHandler(sourceRecordingURL, resolvedModel.url)
        DebugLog.log(
            "Completed Voxtral recorded-WAV transcription. length=\(transcript.count)",
            category: "transcription"
        )
        return transcript
    }

    private func startLiveInputSource(
        configuration: VoxtralLiveInputSourceConfiguration,
        preferredInputDeviceID: String?,
        liveSession: VoxtralLiveSessionHandle?
    ) async throws -> LiveInputSourceStartResult {
        let initialSource = try liveInputSourceFactory(configuration)
        let initialReadiness = try await startAndAwaitLiveInputSource(
            initialSource,
            preferredInputDeviceID: preferredInputDeviceID,
            liveSession: liveSession
        )

        switch initialReadiness {
        case .active:
            return LiveInputSourceStartResult(inputSource: initialSource, inputStatusMessage: nil)
        case .timedOut(let health):
            let emittedSamples = await initialSource.emittedSampleCount()
            if emittedSamples > 0, emittedSamples < Self.minimumHealthyLiveInputSampleCount {
                DebugLog.log(
                    "Voxtral live microphone input stalled before becoming healthy. source=\(initialSource.kindDescription) emittedSamples=\(emittedSamples)",
                    category: "transcription"
                )
            }
            guard case .microphone = configuration,
                  case .awaitingFirstChunk(let selectedInputDeviceID, let defaultInputDeviceID) = health,
                  let selectedInputDeviceID,
                  let defaultInputDeviceID,
                  selectedInputDeviceID != defaultInputDeviceID
            else {
                _ = await initialSource.stop()
                throw BackendError.helperUnavailable(
                    "No live microphone input detected. Check microphone and input device."
                )
            }

            DebugLog.log(
                "No Voxtral live microphone chunks arrived on the selected input. selectedInput=\(selectedInputDeviceID) currentDefault=\(defaultInputDeviceID) action=fallback-to-default",
                category: "transcription"
            )
            pendingStartStatusMessageState = "Trying current macOS default microphone..."
            _ = await initialSource.stop()

            let fallbackSource = try liveInputSourceFactory(.microphone)
            let fallbackReadiness = try await startAndAwaitLiveInputSource(
                fallbackSource,
                preferredInputDeviceID: nil,
                liveSession: liveSession
            )

            switch fallbackReadiness {
            case .active:
                return LiveInputSourceStartResult(
                    inputSource: fallbackSource,
                    inputStatusMessage: "Using current macOS default microphone because the selected input produced no live audio."
                )
            case .timedOut:
                let fallbackSamples = await fallbackSource.emittedSampleCount()
                if fallbackSamples > 0, fallbackSamples < Self.minimumHealthyLiveInputSampleCount {
                    DebugLog.log(
                        "Voxtral default-input fallback also stalled before becoming healthy. emittedSamples=\(fallbackSamples)",
                        category: "transcription"
                    )
                }
                _ = await fallbackSource.stop()
                throw BackendError.helperUnavailable(
                    "No live microphone input detected. Check microphone and input device."
                )
            }
        }
    }

    private func startAndAwaitLiveInputSource(
        _ inputSource: any VoxtralLiveInputSource,
        preferredInputDeviceID: String?,
        liveSession: VoxtralLiveSessionHandle?
    ) async throws -> LiveInputSourceReadiness {
        activeInputSource = inputSource

        if let liveSession {
            await streamingCoordinator.beginStreaming(
                recordingURL: inputSource.recordingURL,
                liveSession: liveSession,
                sourceDescription: inputSource.kindDescription
            )
        }

        DebugLog.log(
            "Starting Voxtral live input source kind=\(inputSource.kindDescription) recording=\(DebugLog.displayPath(inputSource.recordingURL))",
            category: "transcription"
        )

        let streamingCoordinator = self.streamingCoordinator
        try await inputSource.start(
            preferredInputDeviceID: preferredInputDeviceID,
            onSamples: { samples in
                Task {
                    await streamingCoordinator.ingestCapturedSamples(samples)
                }
            },
            onFailure: { reason in
                Task {
                    await streamingCoordinator.handleInputSourceFailure(reason)
                }
            }
        )

        return try await awaitLiveInputSourceReadiness(inputSource)
    }

    private func awaitLiveInputSourceReadiness(
        _ inputSource: any VoxtralLiveInputSource
    ) async throws -> LiveInputSourceReadiness {
        let startTime = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - startTime < Self.liveInputReadyTimeoutNanoseconds {
            if pendingStartCancellationRequested {
                throw CancellationError()
            }

            let health = await inputSource.healthState()
            pendingStartStatusMessageState = health.statusMessage
            switch health {
            case .active:
                pendingStartStatusMessageState = nil
                return .active
            case .failed(let reason):
                throw BackendError.helperUnavailable(reason)
            case .idle, .awaitingFirstChunk:
                break
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return .timedOut(await inputSource.healthState())
    }

    private func createActiveLiveSession(
        resolvedModel providedModel: VoxtralRealtimeResolvedModel? = nil,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        timeoutMessage: String = "The Voxtral helper timed out while starting a live session."
    ) async throws -> VoxtralLiveSessionHandle {
        let resolvedModel: VoxtralRealtimeResolvedModel
        if let providedModel {
            resolvedModel = providedModel
        } else {
            resolvedModel = try await resolveModel()
        }
        preparedModel = resolvedModel
        let helperPreparation = try await helperClient.prepare(modelURL: resolvedModel.url)
        guard helperPreparation.supportsStreamingPreview else {
            throw BackendError.helperUnavailable(
                "The local Voxtral helper does not advertise live preview support yet."
            )
        }

        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(
            id: sessionID,
            modelURL: resolvedModel.url,
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutMessage: timeoutMessage
        )
        DebugLog.log(
            "Started Voxtral live session. model=\(resolvedModel.displayName) session=\(sessionID)",
            category: "transcription"
        )
        return VoxtralLiveSessionHandle(
            sessionID: sessionID,
            modelURL: resolvedModel.url,
            firstPreviewChunkSampleCount: helperPreparation.firstStreamingChunkSampleCount,
            steadyStatePreviewChunkSampleCount: helperPreparation.streamingChunkSampleCount
        )
    }

    private func createLiveSessionForRecording() async throws -> VoxtralLiveSessionHandle {
        let resolvedModel: VoxtralRealtimeResolvedModel
        if let preparedModel {
            resolvedModel = preparedModel
        } else {
            resolvedModel = try await resolveModel()
        }

        DebugLog.log(
            "Starting Voxtral live session for recording. model=\(resolvedModel.displayName)",
            category: "transcription"
        )
        do {
            return try await createActiveLiveSession(
                resolvedModel: resolvedModel,
                timeoutNanoseconds: Self.recordingSessionStartTimeoutNanoseconds,
                timeoutMessage: "The Voxtral helper timed out while starting the live session for recording."
            )
        } catch {
            DebugLog.log(
                "Failed to start the Voxtral live session for recording. model=\(resolvedModel.displayName) error=\(error.localizedDescription)",
                category: "transcription"
            )
            throw error
        }
    }

    private func currentAppBuildVersion() -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(shortVersion)-\(buildNumber)"
    }

    private func resolvedHelperURL() throws -> URL {
        switch VoxtralRealtimeModelLocator.resolveHelper(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager
        ) {
        case .ready(let helperURL):
            return helperURL
        case .invalidEnvironmentPath(let path):
            throw BackendError.helperUnavailable("spk could not find the Voxtral helper at \(path).")
        case .missingHelper:
            throw BackendError.helperUnavailable("spk could not find the bundled Voxtral helper script.")
        }
    }

    private func resolvedPythonURL() throws -> URL {
        switch VoxtralRealtimeModelLocator.resolvePython(
            environment: environment,
            fileManager: fileManager
        ) {
        case .ready(let pythonURL):
            return pythonURL
        case .missingPreferredRuntime:
            return VoxtralRealtimeModelLocator.defaultPythonURL(fileManager: fileManager)
        case .invalidEnvironmentPath(let path):
            throw BackendError.helperUnavailable("spk could not find the Voxtral Python runtime at \(path).")
        }
    }

    private func shouldRebuildPreparedState(stopOutcome: VoxtralStreamingStopOutcome?) -> Bool {
        guard let stopOutcome else {
            return false
        }

        return stopOutcome.failureReason != nil && !stopOutcome.wasCleanUserStop
    }

    private func backgroundRecoveryReason(stopOutcome: VoxtralStreamingStopOutcome?) -> String {
        if let failureReason = stopOutcome?.failureReason, !failureReason.isEmpty {
            return failureReason
        }
        return "the live session became unhealthy"
    }

    private func scheduleBackgroundRecovery(reason: String) {
        backgroundRecoveryTask?.cancel()
        let recoveryID = UUID()
        backgroundRecoveryTaskID = recoveryID
        backgroundRecoveryTask = Task { [self] in
            await rebuildPreparedStateAfterBrokenSession(reason: reason, recoveryID: recoveryID)
        }
    }

    private func resetPreparedStateAfterBrokenSession(reason: String) async {
        DebugLog.log(
            "Invalidating Voxtral readiness after a broken run. reason=\(reason)",
            category: "transcription"
        )
        liveReadyHelperGeneration = nil
        preparationProgressState = nil
        preparationStage = .locatingModel
        lastLoggedPreparationStage = nil
        await streamingCoordinator.clearPreparedLiveSession()
        await helperClient.shutdown()
    }

    private func rebuildPreparedStateAfterBrokenSession(reason: String, recoveryID: UUID) async -> Bool {
        await resetPreparedStateAfterBrokenSession(reason: reason)

        guard !Task.isCancelled else {
            finishBackgroundRecoveryIfCurrent(recoveryID: recoveryID)
            return false
        }

        do {
            _ = try await prepare(cancellingBackgroundRecoveryTask: false)
            DebugLog.log(
                "Rebuilt Voxtral readiness after a broken live session.",
                category: "transcription"
            )
            finishBackgroundRecoveryIfCurrent(recoveryID: recoveryID)
            return true
        } catch {
            DebugLog.log(
                "Failed to rebuild Voxtral readiness after a broken live session: \(error)",
                category: "transcription"
            )
            finishBackgroundRecoveryIfCurrent(recoveryID: recoveryID)
            return false
        }
    }

    private func finishBackgroundRecoveryIfCurrent(recoveryID: UUID) {
        guard backgroundRecoveryTaskID == recoveryID else {
            return
        }
        backgroundRecoveryTask = nil
        backgroundRecoveryTaskID = nil
    }

    private func waitForBackgroundRecoveryIfNeeded() async -> Bool {
        guard let backgroundRecoveryTask else {
            return true
        }
        pendingStartStatusMessageState = "Preparing Voxtral live ingestion..."
        return await backgroundRecoveryTask.value
    }

    private func rebuildPreparedStateSynchronously(
        reason: String,
        statusMessage: String
    ) async throws {
        backgroundRecoveryTask?.cancel()
        backgroundRecoveryTask = nil
        backgroundRecoveryTaskID = nil
        pendingStartStatusMessageState = statusMessage
        DebugLog.log(
            "Attempting immediate Voxtral recovery before retrying recording. reason=\(reason)",
            category: "transcription"
        )
        await resetPreparedStateAfterBrokenSession(reason: reason)
        _ = try await prepare(cancellingBackgroundRecoveryTask: false)
        DebugLog.log(
            "Completed immediate Voxtral recovery before retrying recording.",
            category: "transcription"
        )
    }

    private func shouldRebuildPreparedStateAfterStartFailure(_ error: Error) -> Bool {
        guard let helperError = error as? VoxtralRealtimeHelperClient.HelperError else {
            return false
        }

        switch helperError {
        case .helperFailure(let message), .helperExited(let message):
            return message.contains("starting the live session")
                || message.contains("stopped responding")
        case .missingHelper, .missingRuntime, .malformedResponse:
            return false
        }
    }

    private func backgroundRecoveryReason(afterStartFailure error: Error) -> String {
        if let helperError = error as? VoxtralRealtimeHelperClient.HelperError,
           let description = helperError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    static func resolveLiveInputSourceConfiguration(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> VoxtralLiveInputSourceConfiguration {
        guard let debugAudioPath = environment[Self.debugLiveAudioFileEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !debugAudioPath.isEmpty
        else {
            return .microphone
        }

        let debugAudioURL = URL(fileURLWithPath: debugAudioPath).standardizedFileURL
        guard fileManager.fileExists(atPath: debugAudioURL.path) else {
            throw BackendError.helperUnavailable(
                "spk could not find the Voxtral debug live-audio file at \(debugAudioURL.path)."
            )
        }

        return .replayFile(debugAudioURL)
    }

    private func updatePreparationProgress(
        stage: TranscriptionPreparationStage,
        fraction: Double,
        detail: String
    ) {
        preparationStage = stage
        preparationProgressState = TranscriptionPreparationProgress(
            stage: stage,
            fraction: min(max(fraction, 0), 1),
            detail: detail
        )
        if lastLoggedPreparationStage != stage {
            lastLoggedPreparationStage = stage
            DebugLog.log(
                "Voxtral preparation stage=\(stage.rawValue) detail=\(detail)",
                category: "transcription"
            )
        }
    }

    private func currentModelResolution() async -> VoxtralRealtimeModelResolution {
        let settings = await settingsSnapshotProvider()
        return VoxtralRealtimeModelLocator.resolveModel(
            environment: environment,
            settings: settings,
            fileManager: fileManager
        )
    }

    private func resolveModel() async throws -> VoxtralRealtimeResolvedModel {
        switch await currentModelResolution() {
        case .unsupportedHardware:
            throw BackendError.unsupportedHardware
        case .invalidEnvironmentPath(let path),
             .invalidCustomPath(let path):
            throw BackendError.invalidModelPath(path)
        case .missingModel:
            throw BackendError.missingModel
        case .ready(let resolvedModel):
            return resolvedModel
        }
    }

}
