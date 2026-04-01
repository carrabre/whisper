import Foundation
import XCTest
@testable import spk

final class VoxtralRealtimeStreamingCoordinatorTests: XCTestCase {
    func testStreamingUsesHelperChunkSizesAndImmediatelyDrainsBufferedAudio() async throws {
        DebugLog.resetForTesting()
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeFakeHelper(to: helperURL, eventsURL: eventsURL, fileManager: fileManager)

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )
        let coordinator = VoxtralRealtimeStreamingCoordinator(
            helperClient: helperClient,
            settingsSnapshotProvider: { VoxtralRealtimeSettingsSnapshot(customModelFolderPath: nil) },
            environment: [:],
            fileManager: fileManager
        )

        defer {
            Task {
                _ = await coordinator.stop(recordingURL: nil)
                await helperClient.shutdown()
            }
        }

        let preparation = try await helperClient.prepare(modelURL: modelURL)
        XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
        XCTAssertEqual(preparation.streamingChunkSampleCount, 2)

        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(id: sessionID, modelURL: modelURL)
        let liveSession = VoxtralLiveSessionHandle(
            sessionID: sessionID,
            modelURL: modelURL,
            firstPreviewChunkSampleCount: preparation.firstStreamingChunkSampleCount,
            steadyStatePreviewChunkSampleCount: preparation.streamingChunkSampleCount
        )
        let recordingURL = rootDirectory.appending(path: "test-recording.wav")
        await coordinator.beginStreaming(
            recordingURL: recordingURL,
            liveSession: liveSession,
            sourceDescription: "replay-file"
        )

        await coordinator.ingestCapturedSamples(Array(repeating: 0.2, count: 8))

        try await waitForAsyncCondition(timeout: 2.0) {
            let snapshot = await coordinator.previewSnapshot()
            return snapshot?.currentText == "chunk3"
        }

        let stopResult = await coordinator.stop(recordingURL: recordingURL)
        XCTAssertEqual(stopResult?.bestAvailableTranscript, "chunk3")
        XCTAssertTrue(stopResult?.wasCleanUserStop ?? false)

        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            eventLines,
            [
                "type=load_model",
                "emit=ready",
                "type=start_session",
                "emit=session_started",
                "type=append_audio samples=4",
                "emit=preview_update text=chunk1",
                "type=append_audio samples=2",
                "emit=preview_update text=chunk2",
                "type=append_audio samples=2",
                "emit=preview_update text=chunk3",
                "type=cancel_session",
                "emit=session_cancelled"
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeFakeHelper(
        to helperURL: URL,
        eventsURL _: URL,
        fileManager: FileManager
    ) throws {
        let script = """
        import base64
        import json
        import os
        import sys
        import time

        script_dir = os.path.dirname(os.path.abspath(__file__))
        events_path = os.path.join(script_dir, "helper-events.log")
        preview_count = 0

        def append_event(message):
            with open(events_path, "a", encoding="utf-8") as handle:
                handle.write(message + "\\n")

        def emit(payload):
            extra = ""
            if payload.get("type") == "preview_update":
                extra = f" text={payload.get('text', '')}"
            append_event(f"emit={payload.get('type')}{extra}")
            sys.stdout.write(json.dumps(payload) + "\\n")
            sys.stdout.flush()
            time.sleep(0.01)

        for raw_line in sys.stdin:
            raw_line = raw_line.strip()
            if not raw_line:
                continue

            payload = json.loads(raw_line)
            request_id = payload.get("request_id") or payload.get("requestID")
            request_type = payload.get("type")

            if request_type == "append_audio":
                encoded_samples = payload.get("samples_base64") or payload.get("samplesBase64") or ""
                sample_count = len(base64.b64decode(encoded_samples)) // 2
                append_event(f"type=append_audio samples={sample_count}")
            else:
                append_event(f"type={request_type}")

            if request_type == "load_model":
                model_path = payload.get("model_path") or payload.get("modelPath") or ""
                emit(
                    {
                        "request_id": request_id,
                        "type": "ready",
                        "model_display_name": os.path.basename(model_path),
                        "supports_streaming_preview": True,
                        "first_streaming_chunk_sample_count": 4,
                        "streaming_chunk_sample_count": 2,
                    }
                )
            elif request_type == "start_session":
                emit(
                    {
                        "request_id": request_id,
                        "type": "session_started",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
            elif request_type == "append_audio":
                preview_count += 1
                emit(
                    {
                        "request_id": request_id,
                        "type": "preview_update",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": f"chunk{preview_count}",
                    }
                )
            elif request_type == "cancel_session":
                emit(
                    {
                        "request_id": request_id,
                        "type": "session_cancelled",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
            elif request_type == "shutdown":
                emit({"request_id": request_id, "type": "shutdown"})
                sys.exit(0)
            else:
                emit(
                    {
                        "request_id": request_id,
                        "type": "error",
                        "message": f"unsupported:{request_type}",
                    }
                )
        """

        XCTAssertTrue(
            fileManager.createFile(
                atPath: helperURL.path,
                contents: Data(script.utf8)
            )
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )
    }

    private func waitForAsyncCondition(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the Voxtral streaming condition.")
        throw NSError(domain: "VoxtralRealtimeStreamingCoordinatorTests", code: 1)
    }
}
