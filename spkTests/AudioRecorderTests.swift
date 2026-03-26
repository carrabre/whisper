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
}
