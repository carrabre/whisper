import AVFoundation
import XCTest
@testable import spk

final class AudioRecorderTests: XCTestCase {
    func testRecordingDurationUsesSixteenKilohertzByDefault() {
        let duration = AudioRecorder.recordingDuration(samples: Array(repeating: 0.1, count: 16_000))

        XCTAssertEqual(duration, 1.0, accuracy: 0.0001)
    }

    func testRMSLevelReturnsZeroForEmptySamples() {
        XCTAssertEqual(AudioRecorder.rmsLevel(samples: []), 0)
    }

    func testApplyInputSensitivityClampsAndScalesSamples() {
        let boosted = AudioRecorder.applyInputSensitivity(10.0, to: [0.2, -0.2, 0.8])
        let reduced = AudioRecorder.applyInputSensitivity(0.1, to: [0.2, -0.2, 0.8])

        XCTAssertEqual(boosted, [0.8, -0.8, 1.0])
        XCTAssertEqual(reduced, [0.05, -0.05, 0.2])
    }

    func testPrepareForTranscriptionFromSamplesMatchesExpectedGainDurationAndRMS() {
        let prepared = AudioRecorder.prepareForTranscription(
            samples: [0.2, -0.2, 0.4, -0.4],
            inputSensitivity: 2.0
        )

        XCTAssertEqual(prepared.samples, [0.4, -0.4, 0.8, -0.8])
        XCTAssertEqual(prepared.duration, 4.0 / 16_000.0, accuracy: 0.000001)
        XCTAssertGreaterThan(prepared.rmsLevel, 0.0)
    }

    func testTransientCleanupRemovesFileAfterSuccess() throws {
        let fileURL = temporaryFileURL()
        try Data("test".utf8).write(to: fileURL)

        let result = try AudioRecorder.withTransientRecordingCleanup(at: fileURL) { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTransientCleanupRemovesFileAfterFailure() throws {
        enum SampleError: Error {
            case failed
        }

        let fileURL = temporaryFileURL()
        try Data("test".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try AudioRecorder.withTransientRecordingCleanup(at: fileURL) { _ in
                throw SampleError.failed
            }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCleanupStaleRecordingsRemovesTransientWaveFiles() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let recordingsDirectory = rootDirectory.appending(path: "Recordings")
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let staleRecording = recordingsDirectory.appending(path: "dictation-\(UUID().uuidString).wav")
        let keepFile = recordingsDirectory.appending(path: "keep.txt")
        try Data("audio".utf8).write(to: staleRecording)
        try Data("keep".utf8).write(to: keepFile)

        try AudioRecorder.cleanupStaleRecordings(in: rootDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecording.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepFile.path))

        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testVoxtralReplayFileInputSourceReplaysAudioAndPersistsWaveOutput() async throws {
        let inputURL = temporaryFileURL()
        let expectedSamples = makeSineWaveSamples(sampleCount: 8_000, amplitude: 0.35)
        try writeWaveFile(samples: expectedSamples, to: inputURL)

        let collector = SampleCollector()
        let source = try VoxtralReplayFileInputSource(inputURL: inputURL)

        try await source.start(
            preferredInputDeviceID: nil,
            onSamples: { samples in
                Task { await collector.record(samples) }
            },
            onFailure: { reason in
                Task { await collector.recordFailure(reason) }
            }
        )

        try await waitForCondition(timeout: 3.0) {
            await source.emittedSampleCount() >= expectedSamples.count
        }

        let liveHealthState = await source.healthState()
        let liveNormalizedInputLevel = await source.normalizedInputLevel()
        let stoppedRecordingURL = await source.stop()
        let recordingURL = try XCTUnwrap(stoppedRecordingURL)
        try await waitForCondition(timeout: 1.0) {
            await collector.totalSampleCount() >= expectedSamples.count
        }

        let failureReasons = await collector.failureReasons()
        let emittedSampleCount = await source.emittedSampleCount()
        let stoppedHealthState = await source.healthState()

        XCTAssertEqual(failureReasons, [])
        XCTAssertEqual(emittedSampleCount, expectedSamples.count)
        XCTAssertEqual(liveHealthState, .active(activeInputDeviceID: nil))
        XCTAssertEqual(stoppedHealthState, .idle)
        XCTAssertGreaterThan(liveNormalizedInputLevel, 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))

        let replayedSamples = try AudioRecorder.loadSamples(from: recordingURL, logDiagnostics: false)
        XCTAssertEqual(replayedSamples.count, expectedSamples.count)
        XCTAssertGreaterThan(AudioRecorder.rmsLevel(samples: replayedSamples), 0.01)

        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: recordingURL)
    }

    func testVoxtralLiveInputSourceConfigurationUsesReplayFileOverrideWhenPresent() throws {
        let audioURL = temporaryFileURL()
        try Data("fixture".utf8).write(to: audioURL)

        let configuration = try VoxtralRealtimeTranscriptionBackend.resolveLiveInputSourceConfiguration(
            environment: [VoxtralRealtimeTranscriptionBackend.debugLiveAudioFileEnvironmentKey: audioURL.path],
            fileManager: .default
        )

        XCTAssertEqual(configuration, .replayFile(audioURL.standardizedFileURL))
        try? FileManager.default.removeItem(at: audioURL)
    }

    func testVoxtralLiveInputSourceConfigurationDefaultsToMicrophoneWithoutOverride() throws {
        let configuration = try VoxtralRealtimeTranscriptionBackend.resolveLiveInputSourceConfiguration(
            environment: [:],
            fileManager: .default
        )

        XCTAssertEqual(configuration, .microphone)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("wav")
    }

    private func makeSineWaveSamples(sampleCount: Int, amplitude: Float) -> [Float] {
        (0..<sampleCount).map { index in
            let phase = Double(index) / 16_000.0 * 2.0 * Double.pi * 440.0
            return sin(Float(phase)) * amplitude
        }
    }

    private func writeWaveFile(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(samples.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        buffer.floatChannelData![0].initialize(from: samples, count: samples.count)

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func waitForCondition(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for condition after \(timeout)s")
    }
}

private actor SampleCollector {
    private var totalSamples = 0
    private var failures: [String] = []

    func record(_ samples: [Float]) {
        totalSamples += samples.count
    }

    func recordFailure(_ reason: String) {
        failures.append(reason)
    }

    func totalSampleCount() -> Int {
        totalSamples
    }

    func failureReasons() -> [String] {
        failures
    }
}
