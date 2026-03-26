import AVFoundation
import Foundation

final class LiveCaptureBuffer {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var pendingSamples: [Float] = []

    init?(sourceFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            return nil
        }

        self.outputFormat = outputFormat
        self.converter = converter
    }

    func append(buffer: AVAudioPCMBuffer) {
        converter.reset()

        let estimatedFrames = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 1_024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(estimatedFrames, 1_024)
        ) else {
            return
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
            DebugLog.log("Live capture conversion failed: \(conversionError)", category: "audio")
            return
        }

        guard status == .haveData || status == .endOfStream else {
            DebugLog.log("Live capture conversion returned unsupported status: \(status.rawValue)", category: "audio")
            return
        }

        guard let channelData = outputBuffer.floatChannelData?.pointee else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            DebugLog.log(
                "Live capture conversion produced no samples. sourceFrames=\(buffer.frameLength) sourceRate=\(Int(buffer.format.sampleRate))",
                category: "audio"
            )
            return
        }

        lock.lock()
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
        lock.unlock()
    }

    func takePendingSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard !pendingSamples.isEmpty else { return [] }

        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        return samples
    }

    func reset() {
        lock.lock()
        pendingSamples.removeAll(keepingCapacity: false)
        lock.unlock()
        converter.reset()
    }
}

struct PreparedRecording: Sendable {
    let samples: [Float]
    let duration: Double
    let rmsLevel: Float
}

struct RecordingStopResult: Sendable {
    let recordingURL: URL?
    let trailingLiveSamples: [Float]
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

    private let audioDeviceManager = AudioDeviceManager()
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var previousDefaultInputDeviceID: String?
    private var liveCaptureEngine: AVAudioEngine?
    private var liveCaptureBuffer: LiveCaptureBuffer?
    private var liveCaptureBatchCount = 0
    private var liveCaptureTotalSamples = 0
    private var liveCaptureEmptyPollCount = 0

    func start(preferredInputDeviceID: String?) throws {
        let fileURL = try Self.recordingDirectory()
            .appending(path: "dictation-\(UUID().uuidString).wav")

        let originalDefaultInputDeviceID = audioDeviceManager.defaultInputDeviceID()
        DebugLog.log(
            "Starting recording. Output=\(fileURL.path) preferredInput=\(preferredInputDeviceID ?? "system-default") currentDefault=\(originalDefaultInputDeviceID ?? "unknown")",
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
            startLiveCaptureIfPossible()
            DebugLog.log("Recording started successfully.", category: "audio")
        } catch let recorderError as RecorderError {
            stopLiveCapture()
            restorePreviousInputDeviceIfNeeded()
            DebugLog.log("Recording failed with recorder error: \(recorderError.localizedDescription)", category: "audio")
            throw recorderError
        } catch {
            stopLiveCapture()
            restorePreviousInputDeviceIfNeeded()
            DebugLog.log("Recording failed with unexpected error: \(error)", category: "audio")
            throw RecorderError.couldNotStartRecording
        }
    }

    func stop() -> RecordingStopResult {
        let trailingLiveSamples = liveCaptureBuffer?.takePendingSamples() ?? []
        recorder?.stop()
        recorder = nil
        stopLiveCapture()
        restorePreviousInputDeviceIfNeeded()
        if let currentFileURL {
            DebugLog.log("Stopped recording. File: \(currentFileURL.path)", category: "audio")
        } else {
            DebugLog.log("Stopped recording but no file URL was recorded.", category: "audio")
        }
        let recordingURL = currentFileURL
        currentFileURL = nil
        return RecordingStopResult(
            recordingURL: recordingURL,
            trailingLiveSamples: trailingLiveSamples
        )
    }

    func takeLiveSamples() -> [Float] {
        let samples = liveCaptureBuffer?.takePendingSamples() ?? []
        guard !samples.isEmpty else {
            if liveCaptureEngine != nil {
                liveCaptureEmptyPollCount += 1
                if liveCaptureEmptyPollCount == 5 {
                    DebugLog.log("Live capture polling has not produced any samples yet.", category: "audio")
                }
            }
            return []
        }

        liveCaptureEmptyPollCount = 0
        liveCaptureBatchCount += 1
        liveCaptureTotalSamples += samples.count
        if liveCaptureBatchCount <= 3 || liveCaptureBatchCount % 10 == 0 {
            DebugLog.log(
                "Drained live capture samples. batch=\(liveCaptureBatchCount) count=\(samples.count) total=\(liveCaptureTotalSamples)",
                category: "audio"
            )
        }

        return samples
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        DebugLog.log(
            "Loading samples from \(url.path). sampleRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount)",
            category: "audio"
        )
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
            DebugLog.log("Audio file already matches whisper input format.", category: "audio")
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

        DebugLog.log("Audio converted into whisper input format.", category: "audio")
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
        let samples = try loadSamples(from: url)
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
            rmsLevel: rms
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

    private static func recordingDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "spk/Recordings")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func normalizedInputLevel() -> Float {
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

    private func startLiveCaptureIfPossible() {
        stopLiveCapture()
        liveCaptureBatchCount = 0
        liveCaptureTotalSamples = 0
        liveCaptureEmptyPollCount = 0

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let liveCaptureBuffer = LiveCaptureBuffer(sourceFormat: inputFormat) else {
            DebugLog.log("Live capture setup skipped because a 16 kHz mono converter could not be created.", category: "audio")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            liveCaptureBuffer.append(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            self.liveCaptureEngine = engine
            self.liveCaptureBuffer = liveCaptureBuffer
            DebugLog.log("Live capture engine started for streaming transcription.", category: "audio")
        } catch {
            inputNode.removeTap(onBus: 0)
            DebugLog.log("Live capture engine failed to start: \(error)", category: "audio")
        }
    }

    private func stopLiveCapture() {
        if let liveCaptureEngine {
            DebugLog.log(
                "Stopping live capture engine. batches=\(liveCaptureBatchCount) totalSamples=\(liveCaptureTotalSamples)",
                category: "audio"
            )
            liveCaptureEngine.inputNode.removeTap(onBus: 0)
            liveCaptureEngine.stop()
        }

        liveCaptureEngine = nil
        liveCaptureBuffer?.reset()
        liveCaptureBuffer = nil
        liveCaptureBatchCount = 0
        liveCaptureTotalSamples = 0
        liveCaptureEmptyPollCount = 0
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
