import Foundation

private struct NemotronArtifactManifest: Decodable {
    let version: String
    let runnerProtocolVersion: String
    let runnerExecutableRelativePath: String
    let runnerSourceRelativePath: String
    let checkpointRelativePath: String
}

private struct RunnerCommand: Decodable {
    let command: String
    let chunkMilliseconds: Int?
    let samples: [Float]?
}

private struct RunnerResponse: Encodable {
    let type: String
    let transcript: String?
    let decodeMilliseconds: Double?
    let message: String?
}

private enum RunnerError: LocalizedError {
    case missingArtifactDirectory
    case invalidArguments(String)
    case missingManifest
    case invalidManifest
    case missingRequiredArtifact(String)

    var errorDescription: String? {
        switch self {
        case .missingArtifactDirectory:
            return "Missing required --artifact-dir argument."
        case .invalidArguments(let message):
            return message
        case .missingManifest:
            return "Nemotron runner could not find manifest.json in the artifact directory."
        case .invalidManifest:
            return "Nemotron runner could not decode the artifact manifest."
        case .missingRequiredArtifact(let artifactName):
            return "Nemotron runner is missing \(artifactName)."
        }
    }
}

private struct RunnerContext {
    let artifactDirectory: URL
    let manifest: NemotronArtifactManifest

    static func load(from artifactDirectory: URL) throws -> RunnerContext {
        let manifestURL = artifactDirectory.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RunnerError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try? JSONDecoder().decode(NemotronArtifactManifest.self, from: manifestData) else {
            throw RunnerError.invalidManifest
        }

        try requiredArtifact(
            named: "runner executable",
            relativePath: manifest.runnerExecutableRelativePath,
            in: artifactDirectory,
            mustBeExecutable: true
        )
        try requiredArtifact(
            named: "runner source",
            relativePath: manifest.runnerSourceRelativePath,
            in: artifactDirectory
        )
        try requiredArtifact(
            named: "checkpoint.nemo",
            relativePath: manifest.checkpointRelativePath,
            in: artifactDirectory
        )

        return RunnerContext(
            artifactDirectory: artifactDirectory,
            manifest: manifest
        )
    }

    private static func requiredArtifact(
        named artifactName: String,
        relativePath: String,
        in artifactDirectory: URL,
        mustBeExecutable: Bool = false
    ) throws {
        let artifactURL = artifactDirectory.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw RunnerError.missingRequiredArtifact(artifactName)
        }

        if mustBeExecutable && !FileManager.default.isExecutableFile(atPath: artifactURL.path) {
            throw RunnerError.missingRequiredArtifact("\(artifactName) executable permissions")
        }
    }
}

private enum StartupMode {
    case healthcheck(URL)
    case interactive(URL)
}

private let notImplementedMessage = """
The standalone nemotron-runner target is a legacy scaffold. \
spk now uses the checkpoint-backed Python runtime prepared by the install and dev scripts.
"""

private func parseArguments() throws -> StartupMode {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var artifactDirectory: URL?
    var isHealthcheck = false
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--artifact-dir":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw RunnerError.invalidArguments("Missing value after --artifact-dir.")
            }
            artifactDirectory = URL(fileURLWithPath: arguments[nextIndex], isDirectory: true)
            index += 2
        case "--healthcheck":
            isHealthcheck = true
            index += 1
        default:
            throw RunnerError.invalidArguments("Unknown argument: \(argument)")
        }
    }

    guard let artifactDirectory else {
        throw RunnerError.missingArtifactDirectory
    }

    return isHealthcheck ? .healthcheck(artifactDirectory) : .interactive(artifactDirectory)
}

private func emit(_ response: RunnerResponse) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(response),
          let text = String(data: data, encoding: .utf8) else {
        return
    }

    FileHandle.standardOutput.write(Data(text.utf8))
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func emitErrorAndExit(_ error: Error) -> Never {
    emit(
        RunnerResponse(
            type: "error",
            transcript: nil,
            decodeMilliseconds: nil,
            message: error.localizedDescription
        )
    )
    Foundation.exit(1)
}

private func runInteractive(context: RunnerContext) {
    _ = context
    var hasStarted = false

    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }

        let data = Data(line.utf8)
        guard let command = try? JSONDecoder().decode(RunnerCommand.self, from: data) else {
            emit(
                RunnerResponse(
                    type: "error",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: "Nemotron runner received invalid JSON."
                )
            )
            continue
        }

        switch command.command {
        case "start":
            _ = command.chunkMilliseconds
            hasStarted = false
            emit(
                RunnerResponse(
                    type: "error",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: notImplementedMessage
                )
            )
        case "append":
            _ = command.samples
            emit(
                RunnerResponse(
                    type: "error",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: hasStarted
                        ? notImplementedMessage
                        : "Nemotron runner has not started."
                )
            )
        case "finalize":
            _ = command.samples
            emit(
                RunnerResponse(
                    type: "error",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: hasStarted
                        ? notImplementedMessage
                        : "Nemotron runner has not started."
                )
            )
        case "cancel":
            emit(
                RunnerResponse(
                    type: "cancelled",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: nil
                )
            )
            return
        default:
            emit(
                RunnerResponse(
                    type: "error",
                    transcript: nil,
                    decodeMilliseconds: nil,
                    message: "Unknown command: \(command.command)"
                )
            )
        }
    }
}

do {
    let startupMode = try parseArguments()
    switch startupMode {
    case .healthcheck(let artifactDirectory):
        _ = try RunnerContext.load(from: artifactDirectory)
    case .interactive(let artifactDirectory):
        let context = try RunnerContext.load(from: artifactDirectory)
        runInteractive(context: context)
    }
} catch {
    emitErrorAndExit(error)
}
