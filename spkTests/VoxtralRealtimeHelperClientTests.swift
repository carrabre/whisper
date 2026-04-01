import Foundation
import XCTest
@testable import spk

private enum AsyncTimeoutError: LocalizedError {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Timed out after \(seconds)s"
        }
    }
}

private actor AsyncResultBox<T: Sendable> {
    private var result: Result<T, Error>?

    func store(_ result: Result<T, Error>) {
        guard self.result == nil else {
            return
        }
        self.result = result
    }

    func load() -> Result<T, Error>? {
        result
    }
}

final class VoxtralRealtimeHelperClientTests: XCTestCase {
    func testPrepareReloadsModelAfterHelperRestarts() async throws {
        DebugLog.resetForTesting()
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let stateURL = rootDirectory.appending(path: "helper-state.json")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeFakeHelper(
            to: helperURL,
            stateURL: stateURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitAfterFirstLoadModel: true
        )

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )

        do {
            let preparation = try await helperClient.prepare(modelURL: modelURL)
            XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(preparation.supportsStreamingPreview)

            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let reloadedPreparation = try await helperClient.prepare(modelURL: modelURL)
            XCTAssertEqual(reloadedPreparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(reloadedPreparation.supportsStreamingPreview)

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(
                eventLines,
                [
                    "launch=1 type=load_model loaded=false",
                    "launch=1 emit=ready",
                    "launch=2 type=load_model loaded=false",
                    "launch=2 emit=ready"
                ]
            )
        } catch {
            let helperEvents = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "<missing>"
            await helperClient.shutdown()
            XCTFail("Caught error: \(error)\nHelper events:\n\(helperEvents)")
            return
        }

        await helperClient.shutdown()
    }

    func testProbeStreamingIngestionRequiresFirstAppendBeforeReturning() async throws {
        DebugLog.resetForTesting()
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let stateURL = rootDirectory.appending(path: "helper-state.json")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeFakeHelper(
            to: helperURL,
            stateURL: stateURL,
            eventsURL: eventsURL,
            fileManager: fileManager
        )

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )

        defer {
            Task {
                await helperClient.shutdown()
            }
        }

        do {
            let preparation = try await awaitWithTimeout(seconds: 8) {
                try await helperClient.probeStreamingIngestion(modelURL: modelURL)
            }
            XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(preparation.supportsStreamingPreview)
            XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
            let probeGeneration = await helperClient.currentStreamingProbeGeneration()
            XCTAssertNotNil(probeGeneration)

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(
                eventLines,
                [
                    "launch=1 type=load_model loaded=false",
                    "launch=1 emit=ready",
                    "launch=1 type=start_session loaded=true",
                    "launch=1 emit=session_started",
                    "launch=1 type=append_audio loaded=true",
                    "launch=1 emit=preview_update",
                    "launch=1 type=cancel_session loaded=true",
                    "launch=1 emit=session_cancelled"
                ]
            )
        } catch {
            let helperEvents = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "<missing>"
            let debugLog = DebugLog.snapshotForTesting()
            await helperClient.shutdown()
            XCTFail("Caught error: \(error)\nHelper events:\n\(helperEvents)\nDebug log:\n\(debugLog)")
            return
        }
    }

    func testProbeStreamingIngestionReloadsModelAfterHelperRestarts() async throws {
        DebugLog.resetForTesting()
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        let helperURL = rootDirectory.appending(path: "fake_voxtral_helper.py")
        let modelURL = rootDirectory.appending(path: "FakeModel")
        let stateURL = rootDirectory.appending(path: "helper-state.json")
        let eventsURL = rootDirectory.appending(path: "helper-events.log")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw XCTSkip("The fake Voxtral helper test requires /usr/bin/python3.")
        }

        try fileManager.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try writeFakeHelper(
            to: helperURL,
            stateURL: stateURL,
            eventsURL: eventsURL,
            fileManager: fileManager,
            exitAfterFirstProbeCancel: true
        )

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.helperPathEnvironmentKey: helperURL.path,
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            bundle: Bundle(for: Self.self),
            fileManager: fileManager
        )

        do {
            let preparation = try await awaitWithTimeout(seconds: 8) {
                try await helperClient.probeStreamingIngestion(modelURL: modelURL)
            }
            XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(preparation.supportsStreamingPreview)

            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let reloadedPreparation = try await awaitWithTimeout(seconds: 8) {
                try await helperClient.probeStreamingIngestion(modelURL: modelURL)
            }
            XCTAssertEqual(reloadedPreparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(reloadedPreparation.supportsStreamingPreview)

            let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(
                eventLines,
                [
                    "launch=1 type=load_model loaded=false",
                    "launch=1 emit=ready",
                    "launch=1 type=start_session loaded=true",
                    "launch=1 emit=session_started",
                    "launch=1 type=append_audio loaded=true",
                    "launch=1 emit=preview_update",
                    "launch=1 type=cancel_session loaded=true",
                    "launch=1 emit=session_cancelled",
                    "launch=2 type=load_model loaded=false",
                    "launch=2 emit=ready",
                    "launch=2 type=start_session loaded=true",
                    "launch=2 emit=session_started",
                    "launch=2 type=append_audio loaded=true",
                    "launch=2 emit=preview_update",
                    "launch=2 type=cancel_session loaded=true",
                    "launch=2 emit=session_cancelled"
                ]
            )
        } catch {
            let helperEvents = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "<missing>"
            let debugLog = DebugLog.snapshotForTesting()
            await helperClient.shutdown()
            XCTFail("Caught error: \(error)\nHelper events:\n\(helperEvents)\nDebug log:\n\(debugLog)")
            return
        }

        await helperClient.shutdown()
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
        stateURL _: URL,
        eventsURL _: URL,
        fileManager: FileManager,
        exitAfterFirstLoadModel: Bool = false,
        exitAfterFirstProbeCancel: Bool = false
    ) throws {
        let script = """
        import json
        import os
        import sys
        import time

        script_dir = os.path.dirname(os.path.abspath(__file__))
        state_path = os.path.join(script_dir, "helper-state.json")
        events_path = os.path.join(script_dir, "helper-events.log")
        exit_after_first_load_model = \(exitAfterFirstLoadModel ? "True" : "False")
        exit_after_first_probe_cancel = \(exitAfterFirstProbeCancel ? "True" : "False")

        def load_state():
            if os.path.exists(state_path):
                with open(state_path, "r", encoding="utf-8") as handle:
                    return json.load(handle)
            return {"launch_count": 0, "saw_append": False}

        def save_state(state):
            with open(state_path, "w", encoding="utf-8") as handle:
                json.dump(state, handle)

        def append_event(message):
            with open(events_path, "a", encoding="utf-8") as handle:
                handle.write(message + "\\n")

        state = load_state()
        state["launch_count"] += 1
        state["loaded"] = False
        save_state(state)
        launch_count = state["launch_count"]

        def emit(payload):
            append_event(f"launch={launch_count} emit={payload.get('type')}")
            sys.stdout.write(json.dumps(payload) + "\\n")
            sys.stdout.flush()
            time.sleep(0.05)

        for raw_line in sys.stdin:
            raw_line = raw_line.strip()
            if not raw_line:
                continue

            payload = json.loads(raw_line)
            request_id = payload.get("request_id") or payload.get("requestID")
            request_type = payload.get("type")
            state = load_state()
            loaded = bool(state.get("loaded", False))
            append_event(f"launch={launch_count} type={request_type} loaded={'true' if loaded else 'false'}")

            if request_type == "load_model":
                state["loaded"] = True
                state["saw_append"] = False
                save_state(state)
                model_path = payload.get("model_path") or payload.get("modelPath") or ""
                emit(
                    {
                        "request_id": request_id,
                        "type": "ready",
                        "model_display_name": os.path.basename(model_path),
                        "supports_streaming_preview": True,
                        "first_streaming_chunk_sample_count": 4,
                    }
                )
                if exit_after_first_load_model and launch_count == 1:
                    sys.exit(0)
            elif request_type == "start_session":
                if not loaded:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": "load_model_required",
                        }
                    )
                    continue

                emit(
                    {
                        "request_id": request_id,
                        "type": "session_started",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                    }
                )
            elif request_type == "append_audio":
                if not loaded:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": "load_model_required",
                        }
                    )
                    continue

                state["saw_append"] = True
                save_state(state)
                emit(
                    {
                        "request_id": request_id,
                        "type": "preview_update",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": "",
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
                if exit_after_first_probe_cancel and launch_count == 1 and state.get("saw_append", False):
                    time.sleep(0.1)
                    sys.exit(0)
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
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Timed out waiting for condition after \(timeout)s")
    }

    private func awaitWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let resultBox = AsyncResultBox<T>()
        let task = Task {
            do {
                await resultBox.store(.success(try await operation()))
            } catch {
                await resultBox.store(.failure(error))
            }
        }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = await resultBox.load() {
                task.cancel()
                return try result.get()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        task.cancel()
        throw AsyncTimeoutError.timedOut(seconds)
    }
}
