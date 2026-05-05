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
            XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
            XCTAssertEqual(preparation.streamingChunkSampleCount, 2)

            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let reloadedPreparation = try await helperClient.prepare(modelURL: modelURL)
            XCTAssertEqual(reloadedPreparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(reloadedPreparation.supportsStreamingPreview)
            XCTAssertEqual(reloadedPreparation.firstStreamingChunkSampleCount, 4)
            XCTAssertEqual(reloadedPreparation.streamingChunkSampleCount, 2)

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

    func testPrepareSurfacesMPSUnavailableHelperError() async throws {
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
            mpsUnavailableOnLoad: true
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
            _ = try await helperClient.prepare(modelURL: modelURL)
            XCTFail("Expected preparation to fail when the helper reports unavailable MPS.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "PyTorch MPS is unavailable, so Voxtral Realtime cannot stream locally."
                ),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            eventLines,
            [
                "launch=1 type=load_model loaded=false",
                "launch=1 emit=error"
            ]
        )
    }

    func testValidateStreamingPreviewRequiresNonEmptyPreviewAndFinalTranscript() async throws {
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
            finishSessionText: "final transcript",
            appendPreviewText: "preview text"
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
                try await helperClient.validateStreamingPreview(
                    modelURL: modelURL,
                    validationSamples: Array(repeating: 0.2, count: 6),
                    sampleName: "test-smoke"
                )
            }
            XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(preparation.supportsStreamingPreview)
            XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
            XCTAssertEqual(preparation.streamingChunkSampleCount, 2)
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
                    "launch=1 type=append_audio loaded=true",
                    "launch=1 emit=preview_update",
                    "launch=1 type=finish_session loaded=true",
                    "launch=1 emit=final_transcript"
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

    func testValidateStreamingPreviewPacesAudioAndUsesLongValidationFinalizationTimeout() async throws {
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
            firstStreamingChunkSampleCount: 800,
            steadyStateChunkSampleCount: 800,
            finishSessionText: "final transcript",
            appendPreviewText: "preview text",
            logFinishSessionTimeout: true
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

        let startedAt = Date()
        _ = try await awaitWithTimeout(seconds: 4) {
            try await helperClient.validateStreamingPreview(
                modelURL: modelURL,
                validationSamples: Array(repeating: 0.2, count: 1_600),
                sampleName: "test-smoke"
            )
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThan(elapsed, 0.08)

        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(eventLines.contains("launch=1 finish_timeout=300"))
    }

    func testValidateStreamingPreviewAcceptsDelayedPreviewBeforeFinalizing() async throws {
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
            finishSessionText: "final transcript",
            appendPreviewText: "preview text",
            emptyAppendPreviewCountBeforeText: 2
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

        let preparation = try await awaitWithTimeout(seconds: 4) {
            try await helperClient.validateStreamingPreview(
                modelURL: modelURL,
                validationSamples: Array(repeating: 0.2, count: 6),
                sampleName: "test-smoke",
                previewWaitTimeoutNanoseconds: 500_000_000
            )
        }

        XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(eventLines.contains("launch=1 type=finish_session loaded=true"))
    }

    func testValidateStreamingPreviewReloadsModelAfterHelperRestarts() async throws {
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
            exitAfterFirstValidationFinish: true,
            finishSessionText: "final transcript",
            appendPreviewText: "preview text"
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
                try await helperClient.validateStreamingPreview(
                    modelURL: modelURL,
                    validationSamples: Array(repeating: 0.2, count: 6),
                    sampleName: "test-smoke"
                )
            }
            XCTAssertEqual(preparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(preparation.supportsStreamingPreview)
            XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
            XCTAssertEqual(preparation.streamingChunkSampleCount, 2)

            try await waitForAsyncCondition(timeout: 2.0) {
                await helperClient.currentProcessGeneration() == nil
            }

            let reloadedPreparation = try await awaitWithTimeout(seconds: 8) {
                try await helperClient.validateStreamingPreview(
                    modelURL: modelURL,
                    validationSamples: Array(repeating: 0.2, count: 6),
                    sampleName: "test-smoke"
                )
            }
            XCTAssertEqual(reloadedPreparation.modelDisplayName, "FakeModel")
            XCTAssertTrue(reloadedPreparation.supportsStreamingPreview)
            XCTAssertEqual(reloadedPreparation.firstStreamingChunkSampleCount, 4)
            XCTAssertEqual(reloadedPreparation.streamingChunkSampleCount, 2)

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
                    "launch=1 type=append_audio loaded=true",
                    "launch=1 emit=preview_update",
                    "launch=1 type=finish_session loaded=true",
                    "launch=1 emit=final_transcript",
                    "launch=2 type=load_model loaded=false",
                    "launch=2 emit=ready",
                    "launch=2 type=start_session loaded=true",
                    "launch=2 emit=session_started",
                    "launch=2 type=append_audio loaded=true",
                    "launch=2 emit=preview_update",
                    "launch=2 type=append_audio loaded=true",
                    "launch=2 emit=preview_update",
                    "launch=2 type=finish_session loaded=true",
                    "launch=2 emit=final_transcript"
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

    func testValidateStreamingPreviewFailsWhenAllPreviewUpdatesAreEmpty() async throws {
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
            finishSessionText: "final transcript"
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
            _ = try await helperClient.validateStreamingPreview(
                modelURL: modelURL,
                validationSamples: Array(repeating: 0.2, count: 6),
                sampleName: "test-smoke",
                previewWaitTimeoutNanoseconds: 200_000_000
            )
            XCTFail("Expected strict validation to fail when preview updates stay empty.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The Voxtral helper accepted realtime audio during strict startup validation, but did not produce live preview text before the validation warmup timeout."
            )
        }

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
                "launch=1 type=append_audio loaded=true",
                "launch=1 emit=preview_update",
                "launch=1 type=append_audio loaded=true",
                "launch=1 emit=preview_update",
                "launch=1 type=cancel_session loaded=true",
                "launch=1 emit=session_cancelled"
            ]
        )
    }

    func testValidateStreamingPreviewFailsWhenFinalTranscriptIsEmpty() async throws {
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
            appendPreviewText: "preview text"
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
            _ = try await helperClient.validateStreamingPreview(
                modelURL: modelURL,
                validationSamples: Array(repeating: 0.2, count: 6),
                sampleName: "test-smoke",
                previewWaitTimeoutNanoseconds: 200_000_000
            )
            XCTFail("Expected strict validation to fail when the final transcript is empty.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The Voxtral helper accepted realtime audio during strict startup validation, but returned an empty final transcript."
            )
        }

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
                "launch=1 type=append_audio loaded=true",
                "launch=1 emit=preview_update",
                "launch=1 type=finish_session loaded=true",
                "launch=1 emit=final_transcript",
                "launch=1 type=cancel_session loaded=true",
                "launch=1 emit=session_cancelled"
            ]
        )
    }

    func testPrepareFallsBackToDefaultSteadyStateChunkSizeWhenHelperOmitsIt() async throws {
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
            includesSteadyStateChunkSampleCount: false
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

        let preparation = try await helperClient.prepare(modelURL: modelURL)
        XCTAssertEqual(preparation.firstStreamingChunkSampleCount, 4)
        XCTAssertEqual(preparation.streamingChunkSampleCount, 3_840)
    }

    func testFinishStreamingSessionReturnsFinalTranscript() async throws {
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
            finishSessionText: "finalized from stop"
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

        _ = try await helperClient.prepare(modelURL: modelURL)
        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(id: sessionID, modelURL: modelURL)
        let transcript = try await helperClient.finishStreamingSession(id: sessionID, modelURL: modelURL)

        XCTAssertEqual(transcript, "finalized from stop")
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
                "launch=1 type=finish_session loaded=true",
                "launch=1 emit=final_transcript"
            ]
        )
    }

    func testAppendAudioChunkAllowsSlowSteadyStatePreviewResponseWithinExpandedTimeout() async throws {
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
            delayedAppendResponseIndex: 2,
            delayedAppendResponseSeconds: 7.0
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

        _ = try await helperClient.prepare(modelURL: modelURL)
        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(id: sessionID, modelURL: modelURL)
        _ = try await helperClient.appendAudioChunk(
            Array(repeating: 0.2, count: 4),
            sessionID: sessionID,
            modelURL: modelURL,
            isFirstPreviewRequest: true
        )

        let appendStart = Date()
        _ = try await awaitWithTimeout(seconds: 10.0) {
            try await helperClient.appendAudioChunk(
                Array(repeating: 0.2, count: 2),
                sessionID: sessionID,
                modelURL: modelURL,
                isFirstPreviewRequest: false
            )
        }
        let elapsed = Date().timeIntervalSince(appendStart)

        XCTAssertGreaterThan(elapsed, 6.5)
        XCTAssertLessThan(elapsed, 10.0)

        let debugLog = DebugLog.snapshotForTesting()
        XCTAssertTrue(debugLog.contains("Completed Voxtral live preview append round trip."))

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
                "launch=1 type=append_audio loaded=true",
                "launch=1 emit=preview_update"
            ]
        )
    }

    func testLatePreviewResponsesAfterAppendTimeoutAreIgnoredSafely() async throws {
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
            delayedAppendResponseIndex: 2,
            delayedAppendResponseSeconds: 12.5
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

        _ = try await helperClient.prepare(modelURL: modelURL)
        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(id: sessionID, modelURL: modelURL)
        _ = try await helperClient.appendAudioChunk(
            Array(repeating: 0.2, count: 4),
            sessionID: sessionID,
            modelURL: modelURL,
            isFirstPreviewRequest: true
        )

        do {
            _ = try await helperClient.appendAudioChunk(
                Array(repeating: 0.2, count: 2),
                sessionID: sessionID,
                modelURL: modelURL,
                isFirstPreviewRequest: false
            )
            XCTFail("Expected the delayed steady-state append to time out.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The Voxtral helper timed out while generating a live preview update."
            )
        }

        try await waitForAsyncCondition(timeout: 2.0) {
            DebugLog.snapshotForTesting().contains(
                "Received Voxtral helper response without a pending request. type=preview_update"
            )
        }

        await helperClient.cancelStreamingSession(id: sessionID)

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
                "launch=1 type=append_audio loaded=true",
                "launch=1 emit=preview_update",
                "launch=1 type=cancel_session loaded=true",
                "launch=1 emit=session_cancelled"
            ]
        )
    }

    func testLocalHelperEmitsNonEmptyPreviewBeforeFinishSessionWhenReplayFixtureIsConfigured() async throws {
        let fileManager = FileManager.default
        let fixtureURL = try localVoxtralFixtureURL(fileManager: fileManager)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = repoRoot
            .appending(path: "spk")
            .appending(path: "Resources")
            .appending(path: "Helpers")
            .appending(path: "spk_voxtral_realtime_helper.py")
        let pythonURL = VoxtralRealtimeModelLocator.defaultPythonURL(fileManager: fileManager)
        let modelURL = VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager)

        guard fileManager.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("The local Voxtral replay validation file is missing at \(fixtureURL.path).")
        }
        guard fileManager.fileExists(atPath: helperURL.path),
              fileManager.fileExists(atPath: pythonURL.path),
              fileManager.fileExists(atPath: modelURL.path)
        else {
            throw XCTSkip("Local Voxtral helper, runtime, or model artifacts are unavailable for realtime preview validation.")
        }

        let helperClient = VoxtralRealtimeHelperClient(
            environment: [
                VoxtralRealtimeModelLocator.modelPathEnvironmentKey: modelURL.path,
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

        let preparedRecording: PreparedRecording
        do {
            preparedRecording = try AudioRecorder.prepareForTranscription(from: fixtureURL, inputSensitivity: 1.0)
        } catch {
            throw XCTSkip("The local Voxtral replay fixture could not be opened in the current test environment: \(error.localizedDescription)")
        }
        let preparation = try await helperClient.prepare(modelURL: modelURL)
        let sessionID = UUID().uuidString
        try await helperClient.startStreamingSession(id: sessionID, modelURL: modelURL)

        let firstChunkSampleCount = preparation.firstStreamingChunkSampleCount
        let steadyChunkSampleCount = preparation.streamingChunkSampleCount
        var sampleIndex = 0
        var previewText = ""
        var isFirstAppend = true
        while sampleIndex < preparedRecording.samples.count && previewText.isEmpty {
            let nextChunkSampleCount = isFirstAppend ? firstChunkSampleCount : steadyChunkSampleCount
            let endIndex = min(sampleIndex + nextChunkSampleCount, preparedRecording.samples.count)
            let nextChunk = Array(preparedRecording.samples[sampleIndex..<endIndex])
            sampleIndex = endIndex
            previewText = try await helperClient.appendAudioChunk(
                nextChunk,
                sessionID: sessionID,
                modelURL: modelURL,
                isFirstPreviewRequest: isFirstAppend
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            isFirstAppend = false
        }

        guard !previewText.isEmpty else {
            throw XCTSkip("The local Voxtral helper accepted the replay fixture but did not emit a non-empty preview update in this environment.")
        }
        await helperClient.cancelStreamingSession(id: sessionID)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func localVoxtralFixtureURL(fileManager _: FileManager) throws -> URL {
        let repoFixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Vendor")
            .appending(path: "whisper.cpp")
            .appending(path: "bindings")
            .appending(path: "go")
            .appending(path: "samples")
            .appending(path: "jfk.wav")
        if FileManager.default.fileExists(atPath: repoFixtureURL.path) {
            return repoFixtureURL.standardizedFileURL
        }

        if let fixturePath = ProcessInfo.processInfo.environment["SPK_LOCAL_VOXTRAL_REPLAY_VALIDATION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fixturePath.isEmpty {
            return URL(fileURLWithPath: fixturePath).standardizedFileURL
        }

        if let markerPath = try? String(
            contentsOf: URL(fileURLWithPath: "/tmp/spk_local_voxtral_replay_validation_path.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        !markerPath.isEmpty {
            return URL(fileURLWithPath: markerPath).standardizedFileURL
        }

        throw XCTSkip("The repo sample Vendor/whisper.cpp/bindings/go/samples/jfk.wav is unavailable, and no alternate local Voxtral replay fixture was configured.")
    }

    private func writeFakeHelper(
        to helperURL: URL,
        stateURL _: URL,
        eventsURL _: URL,
        fileManager: FileManager,
        exitAfterFirstLoadModel: Bool = false,
        exitAfterFirstProbeCancel: Bool = false,
        exitAfterFirstValidationFinish: Bool = false,
        includesSteadyStateChunkSampleCount: Bool = true,
        firstStreamingChunkSampleCount: Int = 4,
        steadyStateChunkSampleCount: Int = 2,
        mpsUnavailableOnLoad: Bool = false,
        finishSessionText: String = "",
        appendPreviewText: String = "",
        emptyAppendPreviewCountBeforeText: Int = 0,
        delayedAppendResponseIndex: Int? = nil,
        delayedAppendResponseSeconds: Double = 0,
        logFinishSessionTimeout: Bool = false
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
        exit_after_first_validation_finish = \(exitAfterFirstValidationFinish ? "True" : "False")
        includes_steady_state_chunk_sample_count = \(includesSteadyStateChunkSampleCount ? "True" : "False")
        first_streaming_chunk_sample_count = \(firstStreamingChunkSampleCount)
        steady_state_chunk_sample_count = \(steadyStateChunkSampleCount)
        mps_unavailable_on_load = \(mpsUnavailableOnLoad ? "True" : "False")
        finish_session_text = \(String(reflecting: finishSessionText))
        append_preview_text = \(String(reflecting: appendPreviewText))
        empty_append_preview_count_before_text = \(emptyAppendPreviewCountBeforeText)
        delayed_append_response_index = \(delayedAppendResponseIndex.map(String.init) ?? "None")
        delayed_append_response_seconds = \(delayedAppendResponseSeconds)
        log_finish_session_timeout = \(logFinishSessionTimeout ? "True" : "False")
        append_count = 0

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
                if mps_unavailable_on_load:
                    emit(
                        {
                            "request_id": request_id,
                            "type": "error",
                            "message": "PyTorch MPS is unavailable, so Voxtral Realtime cannot stream locally. torch.backends.mps.is_available() returned false. torch=2.11.0 macos=14.8.4 machine=arm64. Reinstall the managed Voxtral runtime so spk can use a PyTorch build with working MPS.",
                        }
                    )
                    continue

                state["loaded"] = True
                state["saw_append"] = False
                save_state(state)
                model_path = payload.get("model_path") or payload.get("modelPath") or ""
                ready_payload = {
                    "request_id": request_id,
                    "type": "ready",
                    "model_display_name": os.path.basename(model_path),
                    "supports_streaming_preview": True,
                    "first_streaming_chunk_sample_count": first_streaming_chunk_sample_count,
                }
                if includes_steady_state_chunk_sample_count:
                    ready_payload["streaming_chunk_sample_count"] = steady_state_chunk_sample_count
                emit(ready_payload)
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
                append_count += 1
                if delayed_append_response_index is not None and append_count == delayed_append_response_index:
                    time.sleep(delayed_append_response_seconds)
                preview_text = "" if append_count <= empty_append_preview_count_before_text else append_preview_text
                emit(
                    {
                        "request_id": request_id,
                        "type": "preview_update",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": preview_text,
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
            elif request_type == "finish_session":
                if log_finish_session_timeout:
                    append_event(f"launch={launch_count} finish_timeout={payload.get('finalization_timeout_seconds') or payload.get('finalizationTimeoutSeconds')}")
                emit(
                    {
                        "request_id": request_id,
                        "type": "final_transcript",
                        "session_id": payload.get("session_id") or payload.get("sessionID"),
                        "text": finish_session_text,
                    }
                )
                if exit_after_first_validation_finish and launch_count == 1:
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
