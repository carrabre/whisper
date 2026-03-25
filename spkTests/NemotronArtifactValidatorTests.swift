import Foundation
import XCTest
@testable import spk

final class NemotronArtifactValidatorTests: XCTestCase {
    func testValidateAcceptsCompleteArtifactDirectory() throws {
        let release = NemotronArtifactRelease(version: "2026-03-13", runnerProtocolVersion: "1")
        let artifactDirectory = try makeArtifactDirectory(
            version: release.version,
            runnerProtocolVersion: release.runnerProtocolVersion
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let manifest = try loadManifest(from: artifactDirectory)
        let validatedArtifact = try NemotronArtifactValidator(release: release).validate(
            manifest: manifest,
            in: artifactDirectory
        )

        XCTAssertEqual(validatedArtifact.runnerSourceURL.lastPathComponent, "nemotron_runner.py")
        XCTAssertEqual(validatedArtifact.checkpointURL.lastPathComponent, "checkpoint.nemo")
    }

    func testValidateRejectsRunnerProtocolMismatch() throws {
        let release = NemotronArtifactRelease(version: "2026-03-13", runnerProtocolVersion: "1")
        let artifactDirectory = try makeArtifactDirectory(
            version: release.version,
            runnerProtocolVersion: "2"
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let manifest = try loadManifest(from: artifactDirectory)

        XCTAssertThrowsError(
            try NemotronArtifactValidator(release: release).validate(
                manifest: manifest,
                in: artifactDirectory
            )
        ) { error in
            guard case let NemotronBridge.NemotronBridgeError.unsupportedRunnerProtocolVersion(expected, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(expected, "1")
            XCTAssertEqual(actual, "2")
        }
    }

    func testValidateRejectsMissingCheckpointArtifact() throws {
        let release = NemotronArtifactRelease(version: "2026-03-13", runnerProtocolVersion: "1")
        let artifactDirectory = try makeArtifactDirectory(
            version: release.version,
            runnerProtocolVersion: release.runnerProtocolVersion
        )
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        try FileManager.default.removeItem(at: artifactDirectory.appending(path: "checkpoint.nemo"))
        let manifest = try loadManifest(from: artifactDirectory)

        XCTAssertThrowsError(
            try NemotronArtifactValidator(release: release).validate(
                manifest: manifest,
                in: artifactDirectory
            )
        ) { error in
            guard case let NemotronBridge.NemotronBridgeError.missingRequiredArtifact(artifactName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(artifactName, "checkpoint.nemo")
        }
    }

    private func makeArtifactDirectory(
        version: String,
        runnerProtocolVersion: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NemotronArtifactValidatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "runtime"), withIntermediateDirectories: true)

        let runnerURL = root.appending(path: "bin/nemotron-runner")
        let runnerSourceURL = root.appending(path: "runtime/nemotron_runner.py")
        let checkpointURL = root.appending(path: "checkpoint.nemo")
        let manifestURL = root.appending(path: "manifest.json")

        try "#!/usr/bin/env bash\nexit 0\n".write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerURL.path)
        try "print('runner')\n".write(to: runnerSourceURL, atomically: true, encoding: .utf8)
        try Data("checkpoint".utf8).write(to: checkpointURL)

        let manifest = NemotronArtifactManifest(
            version: version,
            runnerProtocolVersion: runnerProtocolVersion,
            runnerExecutableRelativePath: "bin/nemotron-runner",
            runnerSourceRelativePath: "runtime/nemotron_runner.py",
            checkpointRelativePath: "checkpoint.nemo"
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL)

        return root
    }

    private func loadManifest(from artifactDirectory: URL) throws -> NemotronArtifactManifest {
        let manifestURL = artifactDirectory.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(NemotronArtifactManifest.self, from: data)
    }
}
