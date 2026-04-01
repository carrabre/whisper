import AVFoundation
import Foundation

struct PreparedRecording: Sendable {
    let samples: [Float]
    let duration: Double
    let rmsLevel: Float
    let sourceRecordingURL: URL?

    init(
        samples: [Float],
        duration: Double,
        rmsLevel: Float,
        sourceRecordingURL: URL? = nil
    ) {
        self.samples = samples
        self.duration = duration
        self.rmsLevel = rmsLevel
        self.sourceRecordingURL = sourceRecordingURL
    }
}

struct RecordingStopResult: Sendable {
    let recordingURL: URL?
    let bufferedSamples: [Float]?

    init(recordingURL: URL? = nil, bufferedSamples: [Float]? = nil) {
        self.recordingURL = recordingURL
        self.bufferedSamples = bufferedSamples
    }
}

actor AudioRecorder {
    enum RecorderError: LocalizedError {
        case couldNotStartRecording
        case couldNotSwitchInputDevice
        case noAudioSamples
        case unsupportedAudioFormat

        var errorDescription: String? {
            switch self {
            case .couldNotStartRecording:
                return "spk could not start recording from the microphone."
            case .couldNotSwitchInputDevice:
                return "spk could not switch to the selected microphone."
            case .noAudioSamples:
                return "spk could not decode any audio samples from the recording."
            case .unsupportedAudioFormat:
                return "spk could not convert the recording into whisper-compatible audio."
            }
        }
    }

    private let audioDeviceManager: AudioDeviceManager
    private let streamingCoordinator: any StreamingAudioCaptureCoordinating
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var previousDefaultInputDeviceID: String?

    init(
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager(),
        streamingCoordinator: any StreamingAudioCaptureCoordinating = NoopStreamingCaptureCoordinator()
    ) {
        self.audioDeviceManager = audioDeviceManager
        self.streamingCoordinator = streamingCoordinator
    }

    func start(preferredInputDeviceID: String?) async throws -> Bool {
        let fileURL = try Self.recordingDirectory()
            .appending(path: "dictation-\(UUID().uuidString).wav")

        if try await streamingCoordinator.startIfAvailable(
            preferredInputDeviceID: preferredInputDeviceID,
            recordingURL: fileURL
        ) {
            currentFileURL = await streamingCoordinator.currentRecordingURL()
            DebugLog.log(
                "Recording started successfully.",
                category: "audio"
            )
            return true
        }

        let originalDefaultInputDeviceID = audioDeviceManager.defaultInputDeviceID()
        DebugLog.log(
            "Starting recording. output=\(DebugLog.displayPath(fileURL)) preferredInput=\(preferredInputDeviceID ?? "system-default") currentDefault=\(originalDefaultInputDeviceID ?? "unknown")",
            category: "audio"
        )

        if let preferredInputDeviceID,
           preferredInputDeviceID != originalDefaultInputDeviceID {
            do {
                try audioDeviceManager.setDefaultInputDevice(id: preferredInputDeviceID)
                previousDefaultInputDeviceID = originalDefaultInputDeviceID
                DebugLog.log("Switched default input device to \(preferredInputDeviceID)", category: "audio")
            } catch {
                DebugLog.log("Failed to switch input device to \(preferredInputDeviceID): \(error)", category: "audio")
                throw RecorderError.couldNotSwitchInputDevice
            }
        } else {
            previousDefaultInputDeviceID = nil
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()

            guard recorder.record() else {
                restorePreviousInputDeviceIfNeeded()
                DebugLog.log("AVAudioRecorder.record() returned false.", category: "audio")
                throw RecorderError.couldNotStartRecording
            }

            self.recorder = recorder
            currentFileURL = fileURL
            DebugLog.log("Recording started successfully.", category: "audio")
            return false
        } catch let recorderError as RecorderError {
            restorePreviousInputDeviceIfNeeded()
            DebugLog.log("Recording failed with recorder error: \(recorderError.localizedDescription)", category: "audio")
            throw recorderError
        } catch {
            restorePreviousInputDeviceIfNeeded()
            DebugLog.log("Recording failed with unexpected error: \(error)", category: "audio")
            throw RecorderError.couldNotStartRecording
        }
    }

    func stop() async -> RecordingStopResult {
        recorder?.stop()
        recorder = nil
        restorePreviousInputDeviceIfNeeded()

        let persistedRecordingURL = currentFileURL
        let streamingStopResult = await streamingCoordinator.stop()
        let recordingURL = streamingStopResult?.recordingURL ?? persistedRecordingURL
        let bufferedSamples = streamingStopResult?.bufferedSamples

        if let recordingURL {
            DebugLog.log("Stopped recording. file=\(DebugLog.displayPath(recordingURL))", category: "audio")
        } else if bufferedSamples != nil {
            DebugLog.log("Stopped recording using buffered streaming samples.", category: "audio")
        } else {
            DebugLog.log("Stopped recording but no file URL was recorded.", category: "audio")
        }

        currentFileURL = nil
        return RecordingStopResult(
            recordingURL: recordingURL,
            bufferedSamples: bufferedSamples
        )
    }

    func currentRecordingURL() -> URL? {
        currentFileURL
    }

    static func loadSamples(from url: URL, logDiagnostics: Bool = true) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        if logDiagnostics {
            DebugLog.log(
                "Loading samples from \(DebugLog.displayPath(url)). sampleRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount)",
                category: "audio"
            )
        }
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)

        guard let targetFormat else {
            DebugLog.log("Target audio format could not be created.", category: "audio")
            throw RecorderError.unsupportedAudioFormat
        }

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) {
            try file.read(into: buffer)
            if logDiagnostics {
                DebugLog.log("Audio file already matches whisper input format.", category: "audio")
            }
            return try samples(from: buffer)
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RecorderError.unsupportedAudioFormat
        }

        try file.read(into: inputBuffer)

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RecorderError.unsupportedAudioFormat
        }

        let estimatedFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw RecorderError.unsupportedAudioFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
        }

        if let conversionError {
            DebugLog.log("Audio conversion failed: \(conversionError)", category: "audio")
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream else {
            DebugLog.log("Audio conversion ended with unsupported status: \(status.rawValue)", category: "audio")
            throw RecorderError.unsupportedAudioFormat
        }

        if logDiagnostics {
            DebugLog.log("Audio converted into whisper input format.", category: "audio")
        }
        return try samples(from: outputBuffer)
    }

    /// Duration in seconds at 16 kHz.
    static func recordingDuration(samples: [Float], sampleRate: Double = 16_000) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    /// Root-mean-square level (0 = silence, 1 = full scale). Used to detect if any signal was received.
    static func rmsLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    static func applyInputSensitivity(_ sensitivity: Double, to samples: [Float]) -> [Float] {
        let gain = Float(min(max(sensitivity, 0.25), 4.0))
        guard abs(gain - 1.0) > 0.01 else {
            return samples
        }

        return samples.map { sample in
            let boostedSample = sample * gain
            return min(max(boostedSample, -1.0), 1.0)
        }
    }

    static func prepareForTranscription(from url: URL, inputSensitivity: Double) throws -> PreparedRecording {
        let standardizedURL = url.standardizedFileURL
        let samples = try loadSamples(from: standardizedURL)
        return prepareForTranscription(
            samples: samples,
            inputSensitivity: inputSensitivity,
            sourceRecordingURL: standardizedURL
        )
    }

    static func prepareForTranscription(
        samples: [Float],
        inputSensitivity: Double,
        sourceRecordingURL: URL? = nil
    ) -> PreparedRecording {
        let duration = recordingDuration(samples: samples)
        let adjustedSamples = applyInputSensitivity(inputSensitivity, to: samples)
        let rms = rmsLevel(samples: adjustedSamples)

        DebugLog.log(
            "Prepared audio for transcription. samples=\(adjustedSamples.count) duration=\(String(format: "%.2f", duration))s rms=\(String(format: "%.4f", rms))",
            category: "audio"
        )

        return PreparedRecording(
            samples: adjustedSamples,
            duration: duration,
            rmsLevel: rms,
            sourceRecordingURL: sourceRecordingURL
        )
    }

    private static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channelData = buffer.floatChannelData?.pointee else {
            throw RecorderError.noAudioSamples
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            throw RecorderError.noAudioSamples
        }

        return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
    }

    static func cleanupStaleRecordingsIfNeeded() {
        do {
            try cleanupStaleRecordings()
        } catch {
            DebugLog.log("Failed to clean up stale transient recordings: \(error)", category: "audio")
        }
    }

    static func cleanupStaleRecordings(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let recordingDirectory = try recordingDirectory(rootDirectory: directory, fileManager: fileManager)
        guard fileManager.fileExists(atPath: recordingDirectory.path) else { return }

        let items = try fileManager.contentsOfDirectory(
            at: recordingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var removedCount = 0
        for item in items where item.lastPathComponent.hasPrefix("dictation-") && item.pathExtension.lowercased() == "wav" {
            do {
                try fileManager.removeItem(at: item)
                removedCount += 1
            } catch {
                DebugLog.log("Failed to remove a stale transient recording: \(error)", category: "audio")
            }
        }

        if removedCount > 0 {
            DebugLog.log("Removed \(removedCount) stale transient recording(s).", category: "audio")
        }
    }

    static func cleanupRecording(at url: URL, fileManager: FileManager = .default) {
        do {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        } catch {
            DebugLog.log("Failed to remove the transient recording at \(DebugLog.displayPath(url)): \(error)", category: "audio")
        }
    }

    static func withTransientRecordingCleanup<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        defer {
            cleanupRecording(at: url)
        }

        return try body(url)
    }

    private static func recordingDirectory() throws -> URL {
        try recordingDirectory(rootDirectory: nil, fileManager: .default)
    }

    static func makeTransientRecordingURL(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) throws -> URL {
        try recordingDirectory(rootDirectory: rootDirectory, fileManager: fileManager)
            .appending(path: "dictation-\(UUID().uuidString).wav")
    }

    private static func recordingDirectory(
        rootDirectory: URL?,
        fileManager: FileManager
    ) throws -> URL {
        let root = rootDirectory ?? fileManager.temporaryDirectory.appending(path: "spk-transient-recordings")
        let directory = root.appending(path: "Recordings")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func normalizedInputLevel() async -> Float {
        if let streamingSnapshot = await streamingCoordinator.previewSnapshot() {
            return streamingSnapshot.latestRelativeEnergy
        }

        guard let recorder else { return 0 }
        recorder.updateMeters()

        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        let averageLevel = Self.normalizedMeterLevel(for: averagePower)
        let peakLevel = Self.normalizedMeterLevel(for: peakPower)

        return min(max((averageLevel * 0.45) + (peakLevel * 0.8), 0), 1)
    }

    private func restorePreviousInputDeviceIfNeeded() {
        guard let previousDefaultInputDeviceID else { return }
        defer { self.previousDefaultInputDeviceID = nil }
        DebugLog.log("Restoring previous default input device: \(previousDefaultInputDeviceID)", category: "audio")
        try? audioDeviceManager.setDefaultInputDevice(id: previousDefaultInputDeviceID)
    }

    private static func normalizedMeterLevel(for power: Float) -> Float {
        guard power.isFinite else { return 0 }
        let floorPower: Float = -50
        if power <= floorPower { return 0 }
        if power >= 0 { return 1 }

        let normalized = (power - floorPower) / abs(floorPower)
        return min(max(normalized, 0), 1)
    }
}
