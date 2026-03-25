import Foundation

struct NemotronValidatedArtifact: Equatable, Sendable {
    let runnerURL: URL
    let runnerSourceURL: URL
    let checkpointURL: URL
}

struct NemotronArtifactValidator {
    let release: NemotronArtifactRelease

    func validate(
        manifest: NemotronArtifactManifest,
        in artifactDirectory: URL
    ) throws -> NemotronValidatedArtifact {
        guard manifest.version == release.version else {
            DebugLog.log(
                "Nemotron artifact version mismatch. expected=\(release.version) actual=\(manifest.version)",
                category: "model"
            )
            throw NemotronBridge.NemotronBridgeError.invalidArtifactManifest
        }

        guard manifest.runnerProtocolVersion == release.runnerProtocolVersion else {
            DebugLog.log(
                "Nemotron runner protocol mismatch. expected=\(release.runnerProtocolVersion) actual=\(manifest.runnerProtocolVersion)",
                category: "model"
            )
            throw NemotronBridge.NemotronBridgeError.unsupportedRunnerProtocolVersion(
                expected: release.runnerProtocolVersion,
                actual: manifest.runnerProtocolVersion
            )
        }

        let runnerURL = artifactDirectory.appending(path: manifest.runnerExecutableRelativePath)
        guard FileManager.default.fileExists(atPath: runnerURL.path) else {
            DebugLog.log("Nemotron runner missing at \(runnerURL.path)", category: "model")
            throw NemotronBridge.NemotronBridgeError.missingRunnerExecutable
        }

        guard FileManager.default.isExecutableFile(atPath: runnerURL.path) else {
            DebugLog.log("Nemotron runner is not executable at \(runnerURL.path)", category: "model")
            throw NemotronBridge.NemotronBridgeError.missingRunnerExecutable
        }

        let runnerSourceURL = try requiredArtifactURL(
            relativePath: manifest.runnerSourceRelativePath,
            name: "runner source",
            in: artifactDirectory
        )
        let checkpointURL = try requiredArtifactURL(
            relativePath: manifest.checkpointRelativePath,
            name: "checkpoint.nemo",
            in: artifactDirectory
        )

        return NemotronValidatedArtifact(
            runnerURL: runnerURL,
            runnerSourceURL: runnerSourceURL,
            checkpointURL: checkpointURL
        )
    }

    private func requiredArtifactURL(
        relativePath: String,
        name: String,
        in artifactDirectory: URL
    ) throws -> URL {
        let artifactURL = artifactDirectory.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            DebugLog.log("Nemotron artifact missing \(name) at \(artifactURL.path)", category: "model")
            throw NemotronBridge.NemotronBridgeError.missingRequiredArtifact(name)
        }

        return artifactURL
    }
}
