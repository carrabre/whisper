import AVFoundation
import Foundation

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

    func start(preferredInputDeviceID: String?) throws {
        let fileURL = try Self.recordingDirectory()
            .appending(path: "dictation-\(UUID().uuidString).wav")

        let originalDefaultInputDeviceID = audioDeviceManager.defaultInputDeviceID()

        if let preferredInputDeviceID,
           preferredInputDeviceID != originalDefaultInputDeviceID {
            do {
                try audioDeviceManager.setDefaultInputDevice(id: preferredInputDeviceID)
                previousDefaultInputDeviceID = originalDefaultInputDeviceID
            } catch {
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
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()

            guard recorder.record() else {
                restorePreviousInputDeviceIfNeeded()
                throw RecorderError.couldNotStartRecording
            }

            self.recorder = recorder
            currentFileURL = fileURL
        } catch let recorderError as RecorderError {
            restorePreviousInputDeviceIfNeeded()
            throw recorderError
        } catch {
            restorePreviousInputDeviceIfNeeded()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        restorePreviousInputDeviceIfNeeded()
        defer { currentFileURL = nil }
        return currentFileURL
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)

        guard let targetFormat else {
            throw RecorderError.unsupportedAudioFormat
        }

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) {
            try file.read(into: buffer)
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
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream else {
            throw RecorderError.unsupportedAudioFormat
        }

        return try samples(from: outputBuffer)
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

    private func restorePreviousInputDeviceIfNeeded() {
        guard let previousDefaultInputDeviceID else { return }
        defer { self.previousDefaultInputDeviceID = nil }
        try? audioDeviceManager.setDefaultInputDevice(id: previousDefaultInputDeviceID)
    }
}
