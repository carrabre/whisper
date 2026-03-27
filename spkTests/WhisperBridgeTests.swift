import Foundation
import XCTest
@testable import spk

final class WhisperBridgeTests: XCTestCase {
    func testResolveModelPrefersBundledFileOverCachedCopy() async throws {
        let modelDirectory = try makeTemporaryDirectory()
        let bundledModel = modelDirectory.appending(path: "bundled-ggml-base.en-q5_1.bin")
        let cachedModel = modelDirectory.appending(path: "ggml-base.en-q5_1.bin")
        try Data().write(to: bundledModel)
        try Data().write(to: cachedModel)

        let bridge = WhisperBridge(
            environment: ["SPK_WHISPER_MODEL": "base.en-q5_1"],
            modelDirectoryOverrideURL: modelDirectory,
            bundledFileURLOverrides: ["ggml-base.en-q5_1.bin": bundledModel]
        )

        let resolvedURL = try await bridge.resolveModelURLForTesting()

        XCTAssertEqual(resolvedURL, bundledModel)
    }

    func testResolveModelUsesCachedCopyWhenBundleIsMissing() async throws {
        let modelDirectory = try makeTemporaryDirectory()
        let cachedModel = modelDirectory.appending(path: "ggml-base.en-q5_1.bin")
        try Data().write(to: cachedModel)

        let bridge = WhisperBridge(
            environment: ["SPK_WHISPER_MODEL": "base.en-q5_1"],
            modelDirectoryOverrideURL: modelDirectory,
            allowBundledFileLookup: false
        )

        let resolvedURL = try await bridge.resolveModelURLForTesting()

        XCTAssertEqual(resolvedURL, cachedModel)
    }

    func testResolveModelFailsWhenNothingExistsLocally() async {
        do {
            let bridge = WhisperBridge(
                environment: ["SPK_WHISPER_MODEL": "base.en-q5_1"],
                modelDirectoryOverrideURL: try makeTemporaryDirectory(),
                allowBundledFileLookup: false
            )

            _ = try await bridge.resolveModelURLForTesting()
            XCTFail("Expected a missing-model error")
        } catch {
            XCTAssertEqual(
                error as? WhisperBridge.WhisperBridgeError,
                .modelUnavailableLocally(fileName: "ggml-base.en-q5_1.bin")
            )
        }
    }

    func testResolveVADReturnsCachedLocalFileWhenPresent() async throws {
        let modelDirectory = try makeTemporaryDirectory()
        let cachedVAD = modelDirectory.appending(path: "ggml-silero-v6.2.0.bin")
        try Data().write(to: cachedVAD)

        let bridge = WhisperBridge(
            modelDirectoryOverrideURL: modelDirectory,
            allowBundledFileLookup: false
        )

        let resolvedURL = try await bridge.resolveVADModelURLForTesting()

        XCTAssertEqual(resolvedURL, cachedVAD)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
