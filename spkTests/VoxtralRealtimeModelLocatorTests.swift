import Foundation
import XCTest
@testable import spk

final class VoxtralRealtimeModelLocatorTests: XCTestCase {
    func testResolveModelPrefersCustomFolderWhenItLooksValid() throws {
        #if arch(arm64)
        let rootDirectory = try makeTemporaryDirectory()
        try makeModel(at: rootDirectory)

        let resolution = VoxtralRealtimeModelLocator.resolveModel(
            environment: [:],
            settings: VoxtralRealtimeSettingsSnapshot(customModelFolderPath: rootDirectory.path),
            fileManager: .default
        )

        guard case .ready(let resolvedModel) = resolution else {
            return XCTFail("Expected a ready Voxtral model, got \(resolution)")
        }

        XCTAssertEqual(resolvedModel.source, .custom)
        XCTAssertEqual(resolvedModel.url.lastPathComponent, rootDirectory.lastPathComponent)
        #else
        throw XCTSkip("Voxtral Realtime currently requires Apple Silicon.")
        #endif
    }

    func testResolveModelAcceptsTekkenTokenizerLayout() throws {
        #if arch(arm64)
        let rootDirectory = try makeTemporaryDirectory()
        try makeModel(at: rootDirectory, tokenizerFileName: "tekken.json")

        let resolution = VoxtralRealtimeModelLocator.resolveModel(
            environment: [:],
            settings: VoxtralRealtimeSettingsSnapshot(customModelFolderPath: rootDirectory.path),
            fileManager: .default
        )

        guard case .ready(let resolvedModel) = resolution else {
            return XCTFail("Expected a ready Voxtral model, got \(resolution)")
        }

        XCTAssertEqual(resolvedModel.source, .custom)
        XCTAssertEqual(resolvedModel.url.lastPathComponent, rootDirectory.lastPathComponent)
        #else
        throw XCTSkip("Voxtral Realtime currently requires Apple Silicon.")
        #endif
    }

    func testResolveModelReturnsInvalidCustomPathOrFallsBackToInstalledModel() {
        #if arch(arm64)
        let missingPath = "/tmp/does-not-exist-\(UUID().uuidString)"
        let resolution = VoxtralRealtimeModelLocator.resolveModel(
            environment: [:],
            settings: VoxtralRealtimeSettingsSnapshot(customModelFolderPath: missingPath),
            fileManager: .default
        )

        switch resolution {
        case .invalidCustomPath(let path):
            XCTAssertEqual(path, missingPath)
        case .ready(let resolvedModel):
            XCTAssertEqual(resolvedModel.source, .appSupport)
            XCTAssertEqual(
                resolvedModel.url,
                VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: .default)
            )
        default:
            XCTFail("Expected either an invalid custom path or an app support fallback, got \(resolution)")
        }
        #endif
    }

    func testResolvePythonPrefersExplicitEnvironmentOverrideWhenExecutableExists() throws {
        let pythonURL = try makeExecutableFile(named: "python")

        let resolution = VoxtralRealtimeModelLocator.resolvePython(
            environment: [
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: pythonURL.path
            ],
            fileManager: .default
        )

        guard case .ready(let resolvedURL) = resolution else {
            return XCTFail("Expected a ready Python runtime, got \(resolution)")
        }

        XCTAssertEqual(resolvedURL, pythonURL)
    }

    func testResolvePythonReturnsInvalidEnvironmentPathWhenOverrideIsMissing() {
        let missingPath = "/tmp/does-not-exist-\(UUID().uuidString)"
        let resolution = VoxtralRealtimeModelLocator.resolvePython(
            environment: [
                VoxtralRealtimeModelLocator.pythonPathEnvironmentKey: missingPath
            ],
            fileManager: .default
        )

        guard case .invalidEnvironmentPath(let path) = resolution else {
            return XCTFail("Expected an invalid environment path, got \(resolution)")
        }

        XCTAssertEqual(path, missingPath)
    }

    func testReadinessManifestRoundTripsAndValidatesCurrentState() throws {
        let fileManager = FileManager.default
        let helperURL = try makeExecutableFile(
            named: "helper.py",
            contents: "#!/bin/sh\necho helper\n"
        )
        let pythonURL = try makeExecutableFile(
            named: "python",
            contents: "#!/bin/sh\necho Python 3.12.9\n"
        )
        let modelURL = try makeTemporaryDirectory()
        try makeModel(at: modelURL)

        let manifestURL = try makeTemporaryDirectory().appending(path: "readiness.json")

        let manifest = try VoxtralReadinessManifestStore.writeCurrent(
            appBuildVersion: "1.0-1",
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: modelURL,
            manifestURL: manifestURL,
            fileManager: fileManager
        )

        let loadedManifest = VoxtralReadinessManifestStore.load(
            manifestURL: manifestURL,
            fileManager: fileManager
        )
        XCTAssertEqual(loadedManifest?.schemaVersion, manifest.schemaVersion)
        XCTAssertEqual(loadedManifest?.appBuildVersion, manifest.appBuildVersion)
        XCTAssertEqual(loadedManifest?.helperFingerprint, manifest.helperFingerprint)
        XCTAssertEqual(loadedManifest?.pythonVersion, manifest.pythonVersion)
        XCTAssertEqual(loadedManifest?.modelFingerprint, manifest.modelFingerprint)
        XCTAssertEqual(
            VoxtralReadinessManifestStore.validateCurrent(
                appBuildVersion: "1.0-1",
                helperURL: helperURL,
                pythonURL: pythonURL,
                modelURL: modelURL,
                manifestURL: manifestURL,
                fileManager: fileManager
            ),
            .valid
        )
        XCTAssertEqual(
            VoxtralReadinessManifestStore.validateCurrent(
                appBuildVersion: "1.0-2",
                helperURL: helperURL,
                pythonURL: pythonURL,
                modelURL: modelURL,
                manifestURL: manifestURL,
                fileManager: fileManager
            ),
            .invalid("app build changed")
        )
    }

    func testReadinessManifestInvalidatesWhenHelperPathChanges() throws {
        let fileManager = FileManager.default
        let helperURL = try makeExecutableFile(
            named: "helper.py",
            contents: "#!/bin/sh\necho helper\n"
        )
        let replacementHelperURL = try makeExecutableFile(
            named: "other-helper.py",
            contents: "#!/bin/sh\necho helper\n"
        )
        let pythonURL = try makeExecutableFile(
            named: "python",
            contents: "#!/bin/sh\necho Python 3.12.9\n"
        )
        let modelURL = try makeTemporaryDirectory()
        try makeModel(at: modelURL)

        let manifestURL = try makeTemporaryDirectory().appending(path: "readiness.json")

        _ = try VoxtralReadinessManifestStore.writeCurrent(
            appBuildVersion: "1.0-1",
            helperURL: helperURL,
            pythonURL: pythonURL,
            modelURL: modelURL,
            manifestURL: manifestURL,
            fileManager: fileManager
        )

        XCTAssertEqual(
            VoxtralReadinessManifestStore.validateCurrent(
                appBuildVersion: "1.0-1",
                helperURL: replacementHelperURL,
                pythonURL: pythonURL,
                modelURL: modelURL,
                manifestURL: manifestURL,
                fileManager: fileManager
            ),
            .invalid("helper path changed")
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

    private func makeModel(at directory: URL, tokenizerFileName: String = "tokenizer.json") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: directory.appending(path: "config.json").path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: directory.appending(path: "processor_config.json").path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: directory.appending(path: tokenizerFileName).path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: directory.appending(path: "model-00001-of-00002.safetensors").path,
            contents: Data("weights".utf8)
        )
    }

    private func makeExecutableFile(
        named fileName: String,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appending(path: fileName)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: Data(contents.utf8)
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }
}
