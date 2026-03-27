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

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("wav")
    }
}
