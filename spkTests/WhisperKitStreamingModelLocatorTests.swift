import Foundation
import XCTest
@testable import spk

final class WhisperKitStreamingModelLocatorTests: XCTestCase {
    func testResolveModelPrefersMediumCandidateWithinCustomRoot() throws {
        #if arch(arm64)
        let rootDirectory = try makeTemporaryDirectory()
        try makeModel(
            at: rootDirectory.appending(path: "openai_whisper-base.en"),
            tokenizerRepositoryPath: "models/openai/whisper-base.en",
            configuredModelIdentity: "openai/whisper-base.en"
        )
        try makeModel(
            at: rootDirectory.appending(path: "openai_whisper-medium"),
            tokenizerRepositoryPath: "models/openai/whisper-medium",
            configuredModelIdentity: "openai/whisper-medium"
        )

        let resolution = WhisperKitStreamingModelLocator.resolveModel(
            environment: [:],
            settings: WhisperKitStreamingSettingsSnapshot(
                isEnabled: true,
                customModelFolderPath: rootDirectory.path
            ),
            fileManager: .default,
            bundle: .main
        )

        guard case .ready(let resolvedModel) = resolution else {
            return XCTFail("Expected a ready WhisperKit model, got \(resolution)")
        }

        XCTAssertEqual(resolvedModel.source, .custom)
        XCTAssertEqual(resolvedModel.url.lastPathComponent, "openai_whisper-medium")
        #else
        throw XCTSkip("WhisperKit live preview currently requires Apple Silicon.")
        #endif
    }

    func testResolveModelFallsBackToCustomCandidateWhenEnvironmentOverrideIsInvalid() throws {
        #if arch(arm64)
        let rootDirectory = try makeTemporaryDirectory()
        try makeModel(
            at: rootDirectory.appending(path: "openai_whisper-medium"),
            tokenizerRepositoryPath: "models/openai/whisper-medium",
            configuredModelIdentity: "openai/whisper-medium"
        )

        let resolution = WhisperKitStreamingModelLocator.resolveModel(
            environment: [
                WhisperKitStreamingModelLocator.modelPathEnvironmentKey: "/absolute/path/to/local/whisperkit/model-folder"
            ],
            settings: WhisperKitStreamingSettingsSnapshot(
                isEnabled: true,
                customModelFolderPath: rootDirectory.path
            ),
            fileManager: .default,
            bundle: .main
        )

        guard case .ready(let resolvedModel) = resolution else {
            return XCTFail("Expected a ready WhisperKit model, got \(resolution)")
        }

        XCTAssertEqual(resolvedModel.source, .custom)
        XCTAssertEqual(resolvedModel.url.lastPathComponent, "openai_whisper-medium")
        #else
        throw XCTSkip("WhisperKit live preview currently requires Apple Silicon.")
        #endif
    }

    func testResolveModelFallsBackToAvailableLocalModelWhenEnvironmentOverrideIsInvalid() throws {
        #if arch(arm64)
        let resolution = WhisperKitStreamingModelLocator.resolveModel(
            environment: [
                WhisperKitStreamingModelLocator.modelPathEnvironmentKey: "/absolute/path/to/local/whisperkit/model-folder"
            ],
            settings: WhisperKitStreamingSettingsSnapshot(
                isEnabled: true,
                customModelFolderPath: nil
            ),
            fileManager: .default,
            bundle: .main
        )

        guard case .ready(let resolvedModel) = resolution else {
            return XCTFail("Expected a ready WhisperKit model, got \(resolution)")
        }

        XCTAssertNotEqual(resolvedModel.source, .environment)
        #else
        throw XCTSkip("WhisperKit live preview currently requires Apple Silicon.")
        #endif
    }

    func testCoordinatorPreparesConfiguredCustomModel() async throws {
        #if arch(arm64)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelURL = repoRoot.appending(path: "spk/Resources/WhisperKitModels/openai_whisper-medium")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Expected WhisperKit preview model was not found at \(modelURL.path).")
        }

        let coordinator = WhisperKitStreamingCoordinator(
            environment: [:],
            settingsSnapshotProvider: {
                WhisperKitStreamingSettingsSnapshot(
                    isEnabled: true,
                    customModelFolderPath: modelURL.path
                )
            }
        )

        let preparedURL = try await coordinator.prepareIfNeeded()
        let unavailableReason = await coordinator.unavailablePreviewReason()

        XCTAssertEqual(preparedURL?.lastPathComponent, "openai_whisper-medium")
        XCTAssertNil(unavailableReason)
        #else
        throw XCTSkip("WhisperKit live preview currently requires Apple Silicon.")
        #endif
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeModel(
        at directory: URL,
        tokenizerRepositoryPath: String,
        configuredModelIdentity: String
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appending(path: "TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appending(path: "MelSpectrogram.mlmodelc"),
            withIntermediateDirectories: true
        )

        let tokenizerDirectory = directory.appending(path: tokenizerRepositoryPath)
        try FileManager.default.createDirectory(
            at: tokenizerDirectory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: tokenizerDirectory.appending(path: "tokenizer.json").path,
            contents: Data("{}".utf8)
        )
        try Data(#"{"_name_or_path":"\#(configuredModelIdentity)"}"#.utf8).write(
            to: directory.appending(path: "config.json")
        )
    }
}
