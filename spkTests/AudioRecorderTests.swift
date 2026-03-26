import AVFoundation
import XCTest
@testable import spk

final class AudioRecorderTests: XCTestCase {
    func testLiveCaptureBufferReturnsSamplesAcrossMultipleSequentialBuffers() throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let liveCaptureBuffer = try XCTUnwrap(LiveCaptureBuffer(sourceFormat: sourceFormat))

        liveCaptureBuffer.append(buffer: try makeBuffer(format: sourceFormat, frameCount: 4_800, fillValue: 0.2))
        let firstBatch = liveCaptureBuffer.takePendingSamples()

        liveCaptureBuffer.append(buffer: try makeBuffer(format: sourceFormat, frameCount: 4_800, fillValue: -0.2))
        let secondBatch = liveCaptureBuffer.takePendingSamples()

        XCTAssertFalse(firstBatch.isEmpty)
        XCTAssertFalse(secondBatch.isEmpty)
        XCTAssertEqual(firstBatch.count, secondBatch.count)
        XCTAssertGreaterThanOrEqual(firstBatch.count, 1_500)
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        fillValue: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount

        let channelData = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for sampleIndex in 0..<Int(frameCount) {
            channelData[sampleIndex] = fillValue
        }

        return buffer
    }
}
