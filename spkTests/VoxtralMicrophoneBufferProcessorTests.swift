import AVFoundation
import XCTest
@testable import spk

private actor ProcessedSampleBox {
    private var counts: [Int] = []
    private var failures: [String] = []

    func appendCount(_ count: Int) {
        counts.append(count)
    }

    func appendFailure(_ failure: String) {
        failures.append(failure)
    }

    func snapshot() -> (counts: [Int], failures: [String]) {
        (counts, failures)
    }
}

final class VoxtralMicrophoneBufferProcessorTests: XCTestCase {
    func testProcessorReusesConverterAcrossMultipleBuffers() async throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Expected a valid input audio format.")
            return
        }

        let outputExpectation = expectation(description: "converted samples delivered twice")
        outputExpectation.expectedFulfillmentCount = 2

        let processedSampleBox = ProcessedSampleBox()
        var converterCreationCount = 0
        let processor = try VoxtralMicrophoneBufferProcessor(
            inputFormat: inputFormat,
            converterFactory: { inputFormat, targetFormat in
                converterCreationCount += 1
                guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    throw AudioRecorder.RecorderError.unsupportedAudioFormat
                }
                return converter
            },
            onSamples: { samples in
                Task {
                    await processedSampleBox.appendCount(samples.count)
                    outputExpectation.fulfill()
                }
            },
            onFailure: { reason in
                Task {
                    await processedSampleBox.appendFailure(reason)
                }
            }
        )

        processor.enqueue(buffer: try makeInputBuffer(format: inputFormat, frameLength: 4_800))
        processor.enqueue(buffer: try makeInputBuffer(format: inputFormat, frameLength: 4_800))
        processor.drain()

        await fulfillment(of: [outputExpectation], timeout: 2.0)

        let processedSamples = await processedSampleBox.snapshot()
        XCTAssertEqual(converterCreationCount, 1)
        XCTAssertTrue(processedSamples.failures.isEmpty)
        XCTAssertEqual(processedSamples.counts.count, 2)
        XCTAssertEqual(processedSamples.counts[0], processedSamples.counts[1])
        XCTAssertGreaterThan(processedSamples.counts[0], 0)
    }

    private func makeInputBuffer(
        format: AVAudioFormat,
        frameLength: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            XCTFail("Expected an input audio buffer.")
            throw AudioRecorder.RecorderError.unsupportedAudioFormat
        }
        buffer.frameLength = frameLength

        guard let channelData = buffer.floatChannelData?.pointee else {
            XCTFail("Expected float audio channel data.")
            throw AudioRecorder.RecorderError.unsupportedAudioFormat
        }

        let frameCount = Int(frameLength)
        for index in 0..<frameCount {
            channelData[index] = (index % 32) < 16 ? 0.2 : -0.2
        }
        return buffer
    }
}
