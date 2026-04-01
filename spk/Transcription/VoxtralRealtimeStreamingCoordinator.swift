import AVFoundation
import Foundation

struct VoxtralStreamingStopOutcome: Sendable, Equatable {
    let finalTranscript: String?
    let failureReason: String?
    let liveFinalizationSucceeded: Bool
    let previewUpdateCount: Int

    init(
        finalTranscript: String?,
        failureReason: String?,
        liveFinalizationSucceeded: Bool,
        previewUpdateCount: Int = 0
    ) {
        self.finalTranscript = finalTranscript
        self.failureReason = failureReason
        self.liveFinalizationSucceeded = liveFinalizationSucceeded
        self.previewUpdateCount = previewUpdateCount
    }
}

enum VoxtralLiveInputSourceHealth: Sendable, Equatable {
    case idle
    case awaitingFirstChunk(selectedInputDeviceID: String?, defaultInputDeviceID: String?)
    case active(activeInputDeviceID: String?)
    case failed(String)

    var statusMessage: String? {
        switch self {
        case .idle, .active:
            return nil
        case .awaitingFirstChunk:
            return "Listening for microphone input..."
        case .failed(let reason):
            return reason
        }
    }
}

protocol VoxtralLiveInputSource: Sendable {
    var kindDescription: String { get }
    var recordingURL: URL { get }

    func start(
        preferredInputDeviceID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws
    func stop() async -> URL?
    func normalizedInputLevel() async -> Float
    func emittedSampleCount() async -> Int
    func healthState() async -> VoxtralLiveInputSourceHealth
}

private func voxtralRelativeEnergy(for samples: [Float]) -> Float {
    let rms = AudioRecorder.rmsLevel(samples: samples)
    return min(max(rms * 10, 0), 1)
}

private final class VoxtralPersistedRecordingSink {
    let fileURL: URL

    private let fileHandle: FileHandle
    private var dataByteCount = 0
    private var isFinished = false

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileManager.createFile(atPath: fileURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.write(contentsOf: Data(repeating: 0, count: 44))
    }

    func append(samples: [Float]) throws {
        guard !isFinished, !samples.isEmpty else {
            return
        }

        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clippedSample = min(max(sample, -1), 1)
            var intSample = Int16(clippedSample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { bytes in
                data.append(bytes.bindMemory(to: UInt8.self))
            }
        }

        try fileHandle.write(contentsOf: data)
        dataByteCount += data.count
    }

    func finish() throws -> URL {
        guard !isFinished else {
            return fileURL
        }

        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.wavHeader(dataByteCount: dataByteCount))
        try fileHandle.close()
        isFinished = true
        return fileURL
    }

    func discard(fileManager: FileManager = .default) {
        guard !isFinished else {
            return
        }

        do {
            try fileHandle.close()
        } catch {
            DebugLog.log(
                "Failed to close discarded Voxtral recording sink at \(DebugLog.displayPath(fileURL)): \(error)",
                category: "audio"
            )
        }
        isFinished = true
        try? fileManager.removeItem(at: fileURL)
    }

    private static func wavHeader(dataByteCount: Int) -> Data {
        var header = Data()

        func appendASCII(_ text: String) {
            header.append(contentsOf: text.utf8)
        }

        func appendUInt16(_ value: UInt16) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { header.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { header.append(contentsOf: $0) }
        }

        let channelCount: UInt16 = 1
        let sampleRate: UInt32 = 16_000
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let payloadSize = UInt32(dataByteCount)

        appendASCII("RIFF")
        appendUInt32(36 + payloadSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(channelCount)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(payloadSize)

        return header
    }
}

actor VoxtralReplayFileInputSource: VoxtralLiveInputSource {
    private static let replayChunkSampleCount = 3_840

    nonisolated let kindDescription: String
    nonisolated let recordingURL: URL

    private let inputURL: URL
    private let fileManager: FileManager

    private var replayTask: Task<Void, Never>?
    private var sink: VoxtralPersistedRecordingSink?
    private var latestRelativeEnergy: Float = 0
    private var emittedSampleTotal = 0
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var didLogFirstChunk = false
    private var health: VoxtralLiveInputSourceHealth = .idle

    init(inputURL: URL, fileManager: FileManager = .default) throws {
        self.inputURL = inputURL.standardizedFileURL
        self.fileManager = fileManager
        self.recordingURL = try AudioRecorder.makeTransientRecordingURL(fileManager: fileManager)
        self.kindDescription = "replay-file"
    }

    func start(
        preferredInputDeviceID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = preferredInputDeviceID
        self.onSamples = onSamples
        self.onFailure = onFailure
        latestRelativeEnergy = 0
        emittedSampleTotal = 0
        didLogFirstChunk = false
        health = .awaitingFirstChunk(selectedInputDeviceID: nil, defaultInputDeviceID: nil)

        let decodedSamples = try AudioRecorder.loadSamples(from: inputURL)
        sink = try VoxtralPersistedRecordingSink(fileURL: recordingURL, fileManager: fileManager)

        let source = self
        replayTask = Task {
            await source.runReplay(samples: decodedSamples)
        }
    }

    func stop() async -> URL? {
        replayTask?.cancel()
        _ = await replayTask?.value
        replayTask = nil
        onSamples = nil
        onFailure = nil
        latestRelativeEnergy = 0
        health = .idle

        let completedURL = finalizeSink()
        return completedURL
    }

    func normalizedInputLevel() async -> Float {
        latestRelativeEnergy
    }

    func emittedSampleCount() async -> Int {
        emittedSampleTotal
    }

    func healthState() async -> VoxtralLiveInputSourceHealth {
        health
    }

    private func runReplay(samples: [Float]) async {
        for startIndex in stride(from: 0, to: samples.count, by: Self.replayChunkSampleCount) {
            if Task.isCancelled {
                break
            }

            let endIndex = min(startIndex + Self.replayChunkSampleCount, samples.count)
            let chunk = Array(samples[startIndex..<endIndex])

            do {
                try sink?.append(samples: chunk)
            } catch {
                handleFailure("Voxtral replay input could not write the transient WAV. \(error.localizedDescription)")
                return
            }

            emittedSampleTotal += chunk.count
            latestRelativeEnergy = voxtralRelativeEnergy(for: chunk)
            if !didLogFirstChunk {
                didLogFirstChunk = true
                health = .active(activeInputDeviceID: nil)
                DebugLog.log(
                    "Received first Voxtral live input chunk. source=\(kindDescription) samples=\(chunk.count)",
                    category: "transcription"
                )
            }
            onSamples?(chunk)

            do {
                try await Task.sleep(nanoseconds: UInt64((Double(chunk.count) / 16_000) * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func handleFailure(_ reason: String) {
        health = .failed(reason)
        DebugLog.log(
            "Voxtral live input source failed. source=\(kindDescription) emittedSamples=\(emittedSampleTotal) reason=\(reason)",
            category: "transcription"
        )
        onFailure?(reason)
    }

    private func finalizeSink() -> URL? {
        guard let sink else {
            return nil
        }

        self.sink = nil
        do {
            return try sink.finish()
        } catch {
            DebugLog.log(
                "Failed to finalize the Voxtral replay recording at \(DebugLog.displayPath(recordingURL)): \(error)",
                category: "audio"
            )
            sink.discard(fileManager: fileManager)
            return nil
        }
    }
}

private final class VoxtralMicrophoneBufferProcessor {
    private let queue = DispatchQueue(label: "spk.voxtral.microphone.processor")
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let onSamples: @Sendable ([Float]) -> Void
    private let onFailure: @Sendable (String) -> Void

    private var isStopped = false

    init(
        inputFormat: AVAudioFormat,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorder.RecorderError.unsupportedAudioFormat
        }

        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.onSamples = onSamples
        self.onFailure = onFailure
    }

    func enqueue(buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = Self.copy(buffer: buffer) else {
            onFailure("spk could not copy the live microphone buffer for Voxtral.")
            return
        }

        queue.async { [weak self] in
            self?.process(buffer: copiedBuffer)
        }
    }

    func drain() {
        queue.sync {}
    }

    func stop() {
        queue.sync {
            isStopped = true
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard !isStopped else {
            return
        }

        do {
            let samples = try Self.convert(
                buffer: buffer,
                inputFormat: inputFormat,
                targetFormat: targetFormat
            )
            if !samples.isEmpty {
                onSamples(samples)
            }
        } catch {
            isStopped = true
            onFailure("Voxtral microphone input processing failed. \(error.localizedDescription)")
        }
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let sourceChannelData = buffer.floatChannelData,
                  let destinationChannelData = copiedBuffer.floatChannelData else {
                return nil
            }

            for channel in 0..<channelCount {
                destinationChannelData[channel].update(from: sourceChannelData[channel], count: frameCount)
            }
        case .pcmFormatInt16:
            guard let sourceChannelData = buffer.int16ChannelData,
                  let destinationChannelData = copiedBuffer.int16ChannelData else {
                return nil
            }

            for channel in 0..<channelCount {
                destinationChannelData[channel].update(from: sourceChannelData[channel], count: frameCount)
            }
        case .pcmFormatInt32:
            guard let sourceChannelData = buffer.int32ChannelData,
                  let destinationChannelData = copiedBuffer.int32ChannelData else {
                return nil
            }

            for channel in 0..<channelCount {
                destinationChannelData[channel].update(from: sourceChannelData[channel], count: frameCount)
            }
        default:
            return nil
        }

        return copiedBuffer
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorder.RecorderError.unsupportedAudioFormat
        }

        let estimatedFrames = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(estimatedFrames, 1)
        ) else {
            throw AudioRecorder.RecorderError.unsupportedAudioFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream else {
            return []
        }

        guard let channelData = outputBuffer.floatChannelData?.pointee else {
            return []
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }
}

actor VoxtralMicrophoneInputSource: VoxtralLiveInputSource {
    nonisolated let kindDescription = "microphone"
    nonisolated let recordingURL: URL

    private let audioDeviceManager: AudioDeviceManager
    private let fileManager: FileManager

    private var engine: AVAudioEngine?
    private var processor: VoxtralMicrophoneBufferProcessor?
    private var sink: VoxtralPersistedRecordingSink?
    private var latestRelativeEnergy: Float = 0
    private var emittedSampleTotal = 0
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var previousDefaultInputDeviceID: String?
    private var failureAlreadyReported = false
    private var didLogFirstChunk = false
    private var didLogFirstNonSilentChunk = false
    private var didLogFirstBufferCallback = false
    private var activeInputDeviceID: String?
    private var currentDefaultInputDeviceID: String?
    private var health: VoxtralLiveInputSourceHealth = .idle
    private var capturedChunkCount = 0

    init(
        fileManager: FileManager = .default,
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager()
    ) throws {
        self.fileManager = fileManager
        self.audioDeviceManager = audioDeviceManager
        self.recordingURL = try AudioRecorder.makeTransientRecordingURL(fileManager: fileManager)
    }

    func start(
        preferredInputDeviceID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard engine == nil else {
            return
        }

        self.onSamples = onSamples
        self.onFailure = onFailure
        latestRelativeEnergy = 0
        emittedSampleTotal = 0
        failureAlreadyReported = false
        didLogFirstChunk = false
        didLogFirstNonSilentChunk = false
        didLogFirstBufferCallback = false
        activeInputDeviceID = nil
        currentDefaultInputDeviceID = nil
        health = .idle
        capturedChunkCount = 0
        sink = try VoxtralPersistedRecordingSink(fileURL: recordingURL, fileManager: fileManager)

        let originalDefaultInputDeviceID = audioDeviceManager.defaultInputDeviceID()
        currentDefaultInputDeviceID = originalDefaultInputDeviceID
        DebugLog.log(
            "Starting Voxtral live microphone capture. selectedInput=\(preferredInputDeviceID ?? "system-default") currentDefault=\(originalDefaultInputDeviceID ?? "unknown") output=\(DebugLog.displayPath(recordingURL))",
            category: "audio"
        )
        if let preferredInputDeviceID,
           preferredInputDeviceID != originalDefaultInputDeviceID {
            do {
                try audioDeviceManager.setDefaultInputDevice(id: preferredInputDeviceID)
                previousDefaultInputDeviceID = originalDefaultInputDeviceID
                DebugLog.log("Switched default input device to \(preferredInputDeviceID)", category: "audio")
            } catch {
                sink?.discard(fileManager: fileManager)
                sink = nil
                throw AudioRecorder.RecorderError.couldNotSwitchInputDevice
            }
        } else {
            previousDefaultInputDeviceID = nil
        }
        activeInputDeviceID = preferredInputDeviceID ?? originalDefaultInputDeviceID
        health = .awaitingFirstChunk(
            selectedInputDeviceID: preferredInputDeviceID,
            defaultInputDeviceID: originalDefaultInputDeviceID
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        let source = self
        let processor = try VoxtralMicrophoneBufferProcessor(
            inputFormat: inputFormat,
            onSamples: { samples in
                Task {
                    await source.handleCapturedSamples(samples)
                }
            },
            onFailure: { reason in
                Task {
                    await source.handleFailure(reason)
                }
            }
        )

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            Task {
                await source.noteTapBufferCallback(frameLength: Int(buffer.frameLength))
            }
            processor.enqueue(buffer: buffer)
        }
        DebugLog.log(
            "Installed Voxtral live microphone tap. inputFormatSampleRate=\(Int(inputFormat.sampleRate)) channels=\(inputFormat.channelCount) bufferSize=2048",
            category: "audio"
        )

        do {
            let engineStartBegin = DispatchTime.now().uptimeNanoseconds
            DebugLog.log("Starting AVAudioEngine for Voxtral live microphone capture...", category: "audio")
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.processor = processor
            let engineStartDuration = Double(DispatchTime.now().uptimeNanoseconds - engineStartBegin) / 1_000_000_000
            DebugLog.log(
                "Started Voxtral live microphone capture. activeInput=\(activeInputDeviceID ?? "unknown") defaultInput=\(originalDefaultInputDeviceID ?? "unknown") recording=\(DebugLog.displayPath(recordingURL)) engineStartSeconds=\(String(format: "%.3f", engineStartDuration))",
                category: "audio"
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            processor.stop()
            processor.drain()
            restorePreviousInputDeviceIfNeeded()
            sink?.discard(fileManager: fileManager)
            sink = nil
            throw AudioRecorder.RecorderError.couldNotStartRecording
        }
    }

    func stop() async -> URL? {
        let currentEngine = engine
        engine = nil
        currentEngine?.inputNode.removeTap(onBus: 0)
        currentEngine?.stop()

        processor?.stop()
        processor?.drain()
        processor = nil

        restorePreviousInputDeviceIfNeeded()
        onSamples = nil
        onFailure = nil
        activeInputDeviceID = nil
        currentDefaultInputDeviceID = nil
        latestRelativeEnergy = 0
        health = .idle

        let completedURL = finalizeSink()
        return completedURL
    }

    func normalizedInputLevel() async -> Float {
        latestRelativeEnergy
    }

    func emittedSampleCount() async -> Int {
        emittedSampleTotal
    }

    func healthState() async -> VoxtralLiveInputSourceHealth {
        health
    }

    private func handleCapturedSamples(_ samples: [Float]) {
        guard !samples.isEmpty else {
            return
        }

        do {
            try sink?.append(samples: samples)
        } catch {
            handleFailure("Voxtral microphone capture could not write the transient recording. \(error.localizedDescription)")
            return
        }

        emittedSampleTotal += samples.count
        capturedChunkCount += 1
        let rmsLevel = AudioRecorder.rmsLevel(samples: samples)
        latestRelativeEnergy = voxtralRelativeEnergy(for: samples)
        if !didLogFirstChunk {
            didLogFirstChunk = true
            DebugLog.log(
                "Received first Voxtral live input chunk. source=\(kindDescription) activeInput=\(activeInputDeviceID ?? "unknown") defaultInput=\(currentDefaultInputDeviceID ?? "unknown") samples=\(samples.count)",
                category: "transcription"
            )
        }
        if !didLogFirstNonSilentChunk, rmsLevel >= 0.001 {
            didLogFirstNonSilentChunk = true
            DebugLog.log(
                "Received first non-silent Voxtral live input chunk. source=\(kindDescription) activeInput=\(activeInputDeviceID ?? "unknown") rms=\(String(format: "%.4f", rmsLevel)) emittedSamples=\(emittedSampleTotal)",
                category: "transcription"
            )
        }
        if capturedChunkCount >= 2 {
            health = .active(activeInputDeviceID: activeInputDeviceID)
        }
        onSamples?(samples)
    }

    private func noteTapBufferCallback(frameLength: Int) {
        guard !didLogFirstBufferCallback else {
            return
        }

        didLogFirstBufferCallback = true
        DebugLog.log(
            "Received first AVAudioEngine microphone buffer callback for Voxtral. activeInput=\(activeInputDeviceID ?? "unknown") frames=\(frameLength)",
            category: "audio"
        )
    }

    private func handleFailure(_ reason: String) {
        guard !failureAlreadyReported else {
            return
        }

        failureAlreadyReported = true
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        processor?.stop()
        processor?.drain()
        processor = nil
        restorePreviousInputDeviceIfNeeded()
        health = .failed(reason)

        DebugLog.log(
            "Voxtral live input source failed. source=\(kindDescription) emittedSamples=\(emittedSampleTotal) reason=\(reason)",
            category: "transcription"
        )
        onFailure?(reason)
    }

    private func restorePreviousInputDeviceIfNeeded() {
        guard let previousDefaultInputDeviceID else { return }
        defer { self.previousDefaultInputDeviceID = nil }
        DebugLog.log("Restoring previous default input device: \(previousDefaultInputDeviceID)", category: "audio")
        try? audioDeviceManager.setDefaultInputDevice(id: previousDefaultInputDeviceID)
    }

    private func finalizeSink() -> URL? {
        guard let sink else {
            return nil
        }

        self.sink = nil
        do {
            return try sink.finish()
        } catch {
            DebugLog.log(
                "Failed to finalize the Voxtral microphone recording at \(DebugLog.displayPath(recordingURL)): \(error)",
                category: "audio"
            )
            sink.discard(fileManager: fileManager)
            return nil
        }
    }
}

actor VoxtralRealtimeStreamingCoordinator {
    private static let previewChunkSampleCount = 3_840
    private static let speechActivationRmsThreshold: Float = 0.001
    private static let firstPreviewLeadInSampleCount = 1_920

    private let helperClient: VoxtralRealtimeHelperClient

    private var activeRecordingURL: URL?
    private var activeSourceDescription: String?
    private var activeLiveSession: VoxtralLiveSessionHandle?
    private var isStreaming = false

    private var pendingPreviewSamples: [Float] = []
    private var pendingPreviewStartIndex = 0
    private var appendPumpTask: Task<Void, Never>?

    private var currentPreviewText = "Waiting for speech..."
    private var latestRelativeEnergy: Float = 0
    private var previewFailureReason: String?
    private var pendingStopOutcome: VoxtralStreamingStopOutcome?
    private var finalizedSessionTranscript: String?
    private var lastFinalizationFailureReason: String?
    private var liveFinalizationSucceeded = false
    private var nonEmptyPreviewUpdateCount = 0
    private var previewChunkDispatchCount = 0
    private var capturedSampleCount = 0
    private var hasLoggedFirstNonEmptyPreview = false
    private var hasLoggedFirstSourceChunk = false
    private var firstDetectedSpeechSampleOffset: Int?

    init(
        helperClient: VoxtralRealtimeHelperClient,
        settingsSnapshotProvider: @escaping @Sendable () async -> VoxtralRealtimeSettingsSnapshot,
        environment: [String: String],
        fileManager: FileManager
    ) {
        _ = settingsSnapshotProvider
        _ = environment
        _ = fileManager
        self.helperClient = helperClient
    }

    func clearPreparedLiveSession() async {
        appendPumpTask?.cancel()
        appendPumpTask = nil

        if let activeLiveSession {
            await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
        }

        activeLiveSession = nil
        activeRecordingURL = nil
        activeSourceDescription = nil
        isStreaming = false
        previewFailureReason = nil
        pendingStopOutcome = nil
        finalizedSessionTranscript = nil
        lastFinalizationFailureReason = nil
        liveFinalizationSucceeded = false
        currentPreviewText = ""
        latestRelativeEnergy = 0
        pendingPreviewSamples.removeAll(keepingCapacity: false)
        pendingPreviewStartIndex = 0
        previewChunkDispatchCount = 0
        nonEmptyPreviewUpdateCount = 0
        capturedSampleCount = 0
        hasLoggedFirstNonEmptyPreview = false
        hasLoggedFirstSourceChunk = false
        firstDetectedSpeechSampleOffset = nil
    }

    func beginStreaming(
        recordingURL: URL,
        liveSession: VoxtralLiveSessionHandle,
        sourceDescription: String
    ) {
        activeRecordingURL = recordingURL
        activeSourceDescription = sourceDescription
        activeLiveSession = liveSession
        previewFailureReason = nil
        pendingStopOutcome = nil
        finalizedSessionTranscript = nil
        lastFinalizationFailureReason = nil
        liveFinalizationSucceeded = false
        currentPreviewText = "Waiting for speech..."
        latestRelativeEnergy = 0
        pendingPreviewSamples.removeAll(keepingCapacity: false)
        pendingPreviewStartIndex = 0
        previewChunkDispatchCount = 0
        nonEmptyPreviewUpdateCount = 0
        capturedSampleCount = 0
        hasLoggedFirstNonEmptyPreview = false
        hasLoggedFirstSourceChunk = false
        firstDetectedSpeechSampleOffset = nil
        isStreaming = true

        DebugLog.log(
            "Starting Voxtral live preview from \(sourceDescription). recording=\(DebugLog.displayPath(recordingURL))",
            category: "transcription"
        )
    }

    func ingestCapturedSamples(_ samples: [Float]) {
        guard isStreaming, previewFailureReason == nil, !samples.isEmpty else {
            return
        }

        if !hasLoggedFirstSourceChunk {
            hasLoggedFirstSourceChunk = true
            DebugLog.log(
                "Received first Voxtral source chunk. source=\(activeSourceDescription ?? "unknown") samples=\(samples.count)",
                category: "transcription"
            )
        }

        let chunkStartSample = capturedSampleCount
        capturedSampleCount += samples.count
        latestRelativeEnergy = voxtralRelativeEnergy(for: samples)
        pendingPreviewSamples.append(contentsOf: samples)
        if firstDetectedSpeechSampleOffset == nil,
           AudioRecorder.rmsLevel(samples: samples) >= Self.speechActivationRmsThreshold {
            firstDetectedSpeechSampleOffset = max(chunkStartSample - Self.firstPreviewLeadInSampleCount, 0)
            DebugLog.log(
                "Detected Voxtral live speech onset. source=\(activeSourceDescription ?? "unknown") speechStartSample=\(firstDetectedSpeechSampleOffset ?? 0) totalCaptured=\(capturedSampleCount)",
                category: "transcription"
            )
        }
        DebugLog.log(
            "Queued Voxtral live preview samples. source=\(activeSourceDescription ?? "unknown") samples=\(samples.count) totalCaptured=\(capturedSampleCount)",
            category: "transcription"
        )
        ensureAppendPumpRunning()
    }

    func handleInputSourceFailure(_ reason: String) {
        guard previewFailureReason == nil else {
            return
        }

        previewFailureReason = reason
        currentPreviewText = "Live preview unavailable."
        let failureContext = capturedSampleCount == 0
            ? "before any audio chunk arrived"
            : "after \(capturedSampleCount) samples"
        DebugLog.log(
            "Voxtral live input source failed \(failureContext). source=\(activeSourceDescription ?? "unknown") error=\(reason)",
            category: "transcription"
        )
    }

    func stop(recordingURL: URL?) async -> RecordingStopResult? {
        guard isStreaming || activeLiveSession != nil else {
            return nil
        }

        isStreaming = false

        let finalizedRecordingURL = recordingURL ?? activeRecordingURL

        let runningPumpTask = appendPumpTask
        appendPumpTask = nil
        _ = await runningPumpTask?.value

        if let previewFailureReason {
            if let activeLiveSession {
                await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
            }
            pendingStopOutcome = VoxtralStreamingStopOutcome(
                finalTranscript: nil,
                failureReason: previewFailureReason,
                liveFinalizationSucceeded: false,
                previewUpdateCount: nonEmptyPreviewUpdateCount
            )
            activeLiveSession = nil
            activeRecordingURL = nil
            activeSourceDescription = nil
            return RecordingStopResult(recordingURL: finalizedRecordingURL)
        }

        if let activeLiveSession {
            do {
                let residualSamples = drainPendingPreviewSamples()
                if !residualSamples.isEmpty {
                    DebugLog.log(
                        "Dispatching final pending Voxtral live preview chunk. samples=\(residualSamples.count)",
                        category: "transcription"
                    )
                    _ = try await helperClient.appendAudioChunk(
                        residualSamples,
                        sessionID: activeLiveSession.sessionID,
                        modelURL: activeLiveSession.modelURL,
                        isFirstPreviewRequest: previewChunkDispatchCount == 0
                    )
                }

                let finalTranscript = try await helperClient.finishStreamingSession(
                    id: activeLiveSession.sessionID,
                    modelURL: activeLiveSession.modelURL
                )
                finalizedSessionTranscript = finalTranscript
                liveFinalizationSucceeded = true
                pendingStopOutcome = VoxtralStreamingStopOutcome(
                    finalTranscript: finalTranscript,
                    failureReason: nil,
                    liveFinalizationSucceeded: true,
                    previewUpdateCount: nonEmptyPreviewUpdateCount
                )
            } catch {
                let failureReason = error.localizedDescription
                lastFinalizationFailureReason = failureReason
                liveFinalizationSucceeded = false
                pendingStopOutcome = VoxtralStreamingStopOutcome(
                    finalTranscript: nil,
                    failureReason: failureReason,
                    liveFinalizationSucceeded: false,
                    previewUpdateCount: nonEmptyPreviewUpdateCount
                )
                DebugLog.log(
                    "Voxtral live finalization failed. previewUpdateCount=\(nonEmptyPreviewUpdateCount) error=\(failureReason)",
                    category: "transcription"
                )
                await helperClient.cancelStreamingSession(id: activeLiveSession.sessionID)
            }
        }

        activeLiveSession = nil
        activeRecordingURL = nil
        activeSourceDescription = nil
        return RecordingStopResult(recordingURL: finalizedRecordingURL)
    }

    func previewSnapshot() async -> StreamingPreviewSnapshot? {
        guard isStreaming || activeLiveSession != nil else {
            return nil
        }

        return StreamingPreviewSnapshot(
            confirmedText: "",
            unconfirmedText: "",
            currentText: currentPreviewText,
            latestRelativeEnergy: latestRelativeEnergy
        )
    }

    func unavailableReason() -> String? {
        previewFailureReason
    }

    func consumeStopOutcome() -> VoxtralStreamingStopOutcome? {
        defer { pendingStopOutcome = nil }
        return pendingStopOutcome
    }

    private func ensureAppendPumpRunning() {
        guard appendPumpTask == nil, activeLiveSession != nil, previewFailureReason == nil else {
            return
        }

        let coordinator = self
        appendPumpTask = Task {
            await coordinator.runAppendPump()
        }
    }

    private func runAppendPump() async {
        defer {
            appendPumpTask = nil
            if pendingPreviewSampleCount >= Self.previewChunkSampleCount, previewFailureReason == nil {
                ensureAppendPumpRunning()
            }
        }

        while previewFailureReason == nil,
              let activeLiveSession {
            guard prepareForNextPreviewDispatch() else {
                return
            }
            guard let previewChunk = dequeuePreviewChunk(sampleCount: Self.previewChunkSampleCount) else {
                return
            }

            previewChunkDispatchCount += 1
            if previewChunkDispatchCount == 1 {
                DebugLog.log(
                    "Dispatching first Voxtral live preview append. samples=\(previewChunk.count) totalCaptured=\(capturedSampleCount)",
                    category: "transcription"
                )
            }

            do {
                let previewText = try await helperClient.appendAudioChunk(
                    previewChunk,
                    sessionID: activeLiveSession.sessionID,
                    modelURL: activeLiveSession.modelURL,
                    isFirstPreviewRequest: previewChunkDispatchCount == 1
                )
                applyPreviewUpdate(previewText)
            } catch {
                handlePreviewFailure(error.localizedDescription)
                return
            }
        }
    }

    private func applyPreviewUpdate(_ text: String) {
        let normalizedText = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalizedText.isEmpty {
            nonEmptyPreviewUpdateCount += 1
            currentPreviewText = normalizedText
            if !hasLoggedFirstNonEmptyPreview {
                hasLoggedFirstNonEmptyPreview = true
                DebugLog.log(
                    "Received first non-empty Voxtral live partial. text=\(normalizedText)",
                    category: "transcription"
                )
            }
        } else if currentPreviewText.isEmpty {
            currentPreviewText = "Waiting for speech..."
        }
    }

    private func handlePreviewFailure(_ reason: String) {
        guard previewFailureReason == nil else {
            return
        }

        previewFailureReason = reason
        currentPreviewText = "Live preview unavailable."
        DebugLog.log("Voxtral live preview failed during recording: helperFailure(\"\(reason)\")", category: "transcription")
    }

    private func dequeuePreviewChunk(sampleCount: Int) -> [Float]? {
        guard pendingPreviewSampleCount >= sampleCount else {
            return nil
        }

        let endIndex = pendingPreviewStartIndex + sampleCount
        let chunk = Array(pendingPreviewSamples[pendingPreviewStartIndex..<endIndex])
        pendingPreviewStartIndex = endIndex
        trimPendingPreviewBufferIfNeeded()
        return chunk
    }

    private func drainPendingPreviewSamples() -> [Float] {
        guard pendingPreviewSampleCount > 0 else {
            pendingPreviewSamples.removeAll(keepingCapacity: false)
            pendingPreviewStartIndex = 0
            return []
        }

        let samples = Array(pendingPreviewSamples[pendingPreviewStartIndex...])
        pendingPreviewSamples.removeAll(keepingCapacity: false)
        pendingPreviewStartIndex = 0
        return samples
    }

    private var pendingPreviewSampleCount: Int {
        pendingPreviewSamples.count - pendingPreviewStartIndex
    }

    private func prepareForNextPreviewDispatch() -> Bool {
        guard previewChunkDispatchCount == 0 else {
            return pendingPreviewSampleCount >= Self.previewChunkSampleCount
        }

        guard let firstDetectedSpeechSampleOffset else {
            return false
        }

        if pendingPreviewStartIndex < firstDetectedSpeechSampleOffset {
            pendingPreviewStartIndex = min(firstDetectedSpeechSampleOffset, pendingPreviewSamples.count)
        }

        return pendingPreviewSampleCount >= Self.previewChunkSampleCount
    }

    private func trimPendingPreviewBufferIfNeeded() {
        guard pendingPreviewStartIndex > 0,
              pendingPreviewStartIndex >= 8_192,
              pendingPreviewStartIndex * 2 >= pendingPreviewSamples.count
        else {
            return
        }

        pendingPreviewSamples.removeFirst(pendingPreviewStartIndex)
        pendingPreviewStartIndex = 0
    }
}
