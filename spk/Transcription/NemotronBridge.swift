import Foundation

struct NemotronStreamingConfiguration: Sendable {
    let chunkMilliseconds: Int

    static let live = NemotronStreamingConfiguration(chunkMilliseconds: 160)

    var chunkSampleCount: Int {
        max(1, (chunkMilliseconds * 16_000) / 1_000)
    }
}

struct NemotronArtifactManifest: Codable, Sendable {
    let version: String
    let runnerProtocolVersion: String
    let runnerExecutableRelativePath: String
    let runnerSourceRelativePath: String
    let checkpointRelativePath: String
}

protocol NemotronSessionRunning: AnyObject {
    func start(configuration: NemotronStreamingConfiguration) throws
    func appendChunk(samples: [Float]) throws -> StreamingTranscriptionUpdate?
    func finalize(remainingSamples: [Float]) throws -> String
    func cancel()
}

actor NemotronBridge {
    enum NemotronBridgeError: LocalizedError {
        case couldNotCreateModelDirectory
        case modelDownloadFailed
        case invalidDownloadResponse(statusCode: Int?, downloadURL: String)
        case couldNotPrepareRuntime
        case invalidArtifactManifest
        case unsupportedRunnerProtocolVersion(expected: String, actual: String)
        case missingRequiredArtifact(String)
        case missingRunnerExecutable
        case missingBundledRuntimeScript
        case sessionNotStarted
        case runnerFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateModelDirectory:
                return "spk could not create the Nemotron model directory."
            case .modelDownloadFailed:
                return "spk could not download the Nemotron English checkpoint."
            case .invalidDownloadResponse(let statusCode, let downloadURL):
                if statusCode == 404 {
                    return "The Nemotron English checkpoint is missing from the configured download URL (HTTP 404). URL: \(downloadURL)"
                }

                if let statusCode {
                    return "The Nemotron English checkpoint download failed with HTTP \(statusCode). URL: \(downloadURL)"
                }

                return "The Nemotron English checkpoint download did not return a usable HTTP response. URL: \(downloadURL)"
            case .couldNotPrepareRuntime:
                return "spk could not prepare the Nemotron English runtime."
            case .invalidArtifactManifest:
                return "The Nemotron English runtime is missing a valid manifest."
            case .unsupportedRunnerProtocolVersion(let expected, let actual):
                return "The Nemotron English runner protocol version is unsupported. Expected \(expected), got \(actual)."
            case .missingRequiredArtifact(let artifactName):
                return "The Nemotron English runtime is missing \(artifactName)."
            case .missingRunnerExecutable:
                return "The Nemotron English runtime is missing its local runner."
            case .missingBundledRuntimeScript:
                return "spk is missing the bundled Nemotron runner resources."
            case .sessionNotStarted:
                return "spk does not have an active Nemotron English session."
            case .runnerFailed(let message):
                return message
            }
        }
    }

    private struct ArtifactRelease: Sendable {
        let version: String
        let checkpointFileName: String
        let checkpointURL: URL
        let runnerProtocolVersion: String
    }

    private struct StreamingState {
        let configuration: NemotronStreamingConfiguration
        let session: NemotronSessionRunning
        var pendingSamples: [Float] = []
        var receivedSampleCount = 0
        var emittedChunkCount = 0
    }

    private static var artifactRelease: ArtifactRelease {
        let release = NemotronArtifactRelease.current()

        return ArtifactRelease(
            version: release.version,
            checkpointFileName: release.checkpointFileName,
            checkpointURL: release.checkpointURL(),
            runnerProtocolVersion: release.runnerProtocolVersion
        )
    }

    private var streamingState: StreamingState?
    private let sessionFactory: @Sendable (URL, NemotronArtifactManifest) throws -> NemotronSessionRunning

    init(
        sessionFactory: (@Sendable (URL, NemotronArtifactManifest) throws -> NemotronSessionRunning)? = nil
    ) {
        self.sessionFactory = sessionFactory ?? { artifactDirectory, manifest in
            try NemotronRunnerProcessSession(
                artifactDirectory: artifactDirectory,
                manifest: manifest
            )
        }
    }

    deinit {
        streamingState?.session.cancel()
    }

    func modelDirectoryURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "spk/Models/nemotron-en")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("Failed to create Nemotron model directory at \(directory.path): \(error)", category: "model")
            throw NemotronBridgeError.couldNotCreateModelDirectory
        }

        return directory
    }

    func prepareModel() async throws -> URL {
        let artifactDirectory = try artifactDirectoryURL()
        if let manifest = try loadManifestIfPresent(in: artifactDirectory) {
            _ = try validateManifest(manifest, in: artifactDirectory)
            try performRunnerHandshake(in: artifactDirectory, manifest: manifest)
            DebugLog.log("Using cached Nemotron runtime at \(artifactDirectory.path)", category: "model")
            return artifactDirectory
        }

        DebugLog.log(
            "No local Nemotron runtime found. Preparing checkpoint-backed runtime at \(artifactDirectory.path)",
            category: "model"
        )
        try await bootstrapArtifactRuntime(to: artifactDirectory)
        let manifest = try validatedManifest(in: artifactDirectory)
        try performRunnerHandshake(in: artifactDirectory, manifest: manifest)
        return artifactDirectory
    }

    func startStreaming(configuration: NemotronStreamingConfiguration = .live) async throws {
        let artifactDirectory = try await prepareModel()
        let manifest = try validatedManifest(in: artifactDirectory)
        stopStreaming()

        let session = try sessionFactory(artifactDirectory, manifest)
        try session.start(configuration: configuration)
        streamingState = StreamingState(
            configuration: configuration,
            session: session
        )
        DebugLog.log(
            "Started Nemotron English streaming. chunkMs=\(configuration.chunkMilliseconds) chunkSamples=\(configuration.chunkSampleCount)",
            category: "transcription"
        )
    }

    func appendStreamingSamples(_ samples: [Float]) throws -> StreamingTranscriptionUpdate? {
        guard var streamingState else {
            throw NemotronBridgeError.sessionNotStarted
        }

        guard !samples.isEmpty else {
            self.streamingState = streamingState
            return nil
        }

        streamingState.receivedSampleCount += samples.count
        streamingState.pendingSamples.append(contentsOf: samples)

        var latestUpdate: StreamingTranscriptionUpdate?
        while streamingState.pendingSamples.count >= streamingState.configuration.chunkSampleCount {
            let chunk = Array(streamingState.pendingSamples.prefix(streamingState.configuration.chunkSampleCount))
            streamingState.pendingSamples.removeFirst(streamingState.configuration.chunkSampleCount)
            streamingState.emittedChunkCount += 1

            if let update = try streamingState.session.appendChunk(samples: chunk),
               !update.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestUpdate = update
            }
        }

        self.streamingState = streamingState
        return latestUpdate
    }

    func finalizeStreaming(trailingSamples: [Float]) throws -> String {
        guard var streamingState else {
            throw NemotronBridgeError.sessionNotStarted
        }

        if !trailingSamples.isEmpty {
            streamingState.pendingSamples.append(contentsOf: trailingSamples)
            streamingState.receivedSampleCount += trailingSamples.count
        }

        while streamingState.pendingSamples.count >= streamingState.configuration.chunkSampleCount {
            let chunk = Array(streamingState.pendingSamples.prefix(streamingState.configuration.chunkSampleCount))
            streamingState.pendingSamples.removeFirst(streamingState.configuration.chunkSampleCount)
            streamingState.emittedChunkCount += 1
            _ = try streamingState.session.appendChunk(samples: chunk)
        }

        let remainingSamples = streamingState.pendingSamples
        let finalTranscript = try streamingState.session.finalize(remainingSamples: remainingSamples)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DebugLog.log(
            "Finalized Nemotron English session. totalSamples=\(streamingState.receivedSampleCount) emittedChunks=\(streamingState.emittedChunkCount) remainingSamples=\(remainingSamples.count) finalLength=\(finalTranscript.count)",
            category: "transcription"
        )

        streamingState.session.cancel()
        self.streamingState = nil
        return finalTranscript
    }

    func stopStreaming() {
        if let streamingState {
            DebugLog.log(
                "Stopping Nemotron English session. totalSamples=\(streamingState.receivedSampleCount) emittedChunks=\(streamingState.emittedChunkCount) pending=\(streamingState.pendingSamples.count)",
                category: "transcription"
            )
            streamingState.session.cancel()
        }

        streamingState = nil
    }

    private func artifactDirectoryURL() throws -> URL {
        try modelDirectoryURL().appending(path: Self.artifactRelease.version)
    }

    private func bootstrapArtifactRuntime(to artifactDirectory: URL) async throws {
        let stagingDirectory = artifactDirectory
            .deletingLastPathComponent()
            .appending(path: "\(Self.artifactRelease.version).staging")

        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.removeItem(at: artifactDirectory)

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory.appending(path: "bin"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: stagingDirectory.appending(path: "runtime"),
                withIntermediateDirectories: true
            )

            let runnerSourceURL = try bundledRunnerSourceURL()
            let stagedRunnerSourceURL = stagingDirectory.appending(path: "runtime/nemotron_runner.py")
            try FileManager.default.copyItem(at: runnerSourceURL, to: stagedRunnerSourceURL)

            let checkpointURL = stagingDirectory.appending(path: Self.artifactRelease.checkpointFileName)
            try await downloadCheckpoint(to: checkpointURL)
            try writeRunnerWrapper(to: stagingDirectory.appending(path: "bin/nemotron-runner"))

            let manifest = NemotronArtifactManifest(
                version: Self.artifactRelease.version,
                runnerProtocolVersion: Self.artifactRelease.runnerProtocolVersion,
                runnerExecutableRelativePath: "bin/nemotron-runner",
                runnerSourceRelativePath: "runtime/nemotron_runner.py",
                checkpointRelativePath: Self.artifactRelease.checkpointFileName
            )
            try JSONEncoder().encode(manifest).write(
                to: stagingDirectory.appending(path: "manifest.json"),
                options: [.atomic]
            )

            try FileManager.default.moveItem(at: stagingDirectory, to: artifactDirectory)
            DebugLog.log("Nemotron runtime ready at \(artifactDirectory.path)", category: "model")
        } catch let error as NemotronBridgeError {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            DebugLog.log("Nemotron runtime preparation failed: \(error)", category: "model")
            throw NemotronBridgeError.couldNotPrepareRuntime
        }
    }

    private func loadManifestIfPresent(in artifactDirectory: URL) throws -> NemotronArtifactManifest? {
        let manifestURL = artifactDirectory.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(NemotronArtifactManifest.self, from: data)
    }

    private func validatedManifest(in artifactDirectory: URL) throws -> NemotronArtifactManifest {
        guard let manifest = try loadManifestIfPresent(in: artifactDirectory) else {
            DebugLog.log("Nemotron artifact manifest was missing at \(artifactDirectory.path)", category: "model")
            throw NemotronBridgeError.invalidArtifactManifest
        }

        _ = try validateManifest(manifest, in: artifactDirectory)
        return manifest
    }

    @discardableResult
    private func validateManifest(
        _ manifest: NemotronArtifactManifest,
        in artifactDirectory: URL
    ) throws -> NemotronValidatedArtifact {
        let validator = NemotronArtifactValidator(
            release: NemotronArtifactRelease(
                version: Self.artifactRelease.version,
                runnerProtocolVersion: Self.artifactRelease.runnerProtocolVersion
            )
        )

        return try validator.validate(
            manifest: manifest,
            in: artifactDirectory
        )
    }

    private func performRunnerHandshake(
        in artifactDirectory: URL,
        manifest: NemotronArtifactManifest
    ) throws {
        let session = try sessionFactory(artifactDirectory, manifest)

        do {
            try session.start(configuration: .live)
            session.cancel()
        } catch let error as NemotronBridgeError {
            session.cancel()
            throw error
        } catch {
            session.cancel()
            throw NemotronBridgeError.runnerFailed(error.localizedDescription)
        }
    }

    private func downloadCheckpoint(to checkpointURL: URL) async throws {
        let (downloadedURL, response) = try await URLSession.shared.download(from: Self.artifactRelease.checkpointURL)

        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            if let response = response as? HTTPURLResponse {
                DebugLog.log(
                    "Nemotron checkpoint download returned HTTP \(response.statusCode). url=\(Self.artifactRelease.checkpointURL.absoluteString)",
                    category: "model"
                )
                throw NemotronBridgeError.invalidDownloadResponse(
                    statusCode: response.statusCode,
                    downloadURL: Self.artifactRelease.checkpointURL.absoluteString
                )
            }

            DebugLog.log(
                "Nemotron checkpoint download returned a non-HTTP response. url=\(Self.artifactRelease.checkpointURL.absoluteString)",
                category: "model"
            )
            throw NemotronBridgeError.invalidDownloadResponse(
                statusCode: nil,
                downloadURL: Self.artifactRelease.checkpointURL.absoluteString
            )
        }

        do {
            try FileManager.default.moveItem(at: downloadedURL, to: checkpointURL)
        } catch {
            DebugLog.log("Nemotron checkpoint move failed: \(error)", category: "model")
            throw NemotronBridgeError.modelDownloadFailed
        }
    }

    private func bundledRunnerSourceURL(bundle: Bundle = .main) throws -> URL {
        if let resourceURL = bundle.url(
            forResource: "nemotron_runner",
            withExtension: "py",
            subdirectory: "NemotronRuntime"
        ) {
            return resourceURL
        }

        if let resourceURL = bundle.url(
            forResource: "nemotron_runner",
            withExtension: "py"
        ) {
            return resourceURL
        }

        DebugLog.log("Bundled Nemotron runner source was missing from app resources.", category: "model")
        throw NemotronBridgeError.missingBundledRuntimeScript
    }

    private func writeRunnerWrapper(to runnerURL: URL) throws {
        let wrapper = """
        #!/usr/bin/env bash
        set -euo pipefail

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        ARTIFACT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
        CANDIDATE_PYTHONS=()

        if [[ -n "${SPK_NEMOTRON_RUNTIME_PYTHON:-}" ]]; then
          CANDIDATE_PYTHONS+=("${SPK_NEMOTRON_RUNTIME_PYTHON}")
        fi

        if [[ -n "${SPK_NEMOTRON_EXPORT_PYTHON:-}" ]]; then
          CANDIDATE_PYTHONS+=("${SPK_NEMOTRON_EXPORT_PYTHON}")
        fi

        CANDIDATE_PYTHONS+=(
          "${HOME}/Library/Application Support/spk/Tools/nemotron-python/bin/python3"
          "python3"
        )

        for candidate in "${CANDIDATE_PYTHONS[@]}"; do
          if [[ -x "$candidate" ]]; then
            exec "$candidate" "${ARTIFACT_DIR}/runtime/nemotron_runner.py" "$@"
          fi
          if command -v "$candidate" >/dev/null 2>&1; then
            exec "$candidate" "${ARTIFACT_DIR}/runtime/nemotron_runner.py" "$@"
          fi
        done

        while IFS= read -r _line; do
          printf '%s\\n' '{"type":"error","message":"Nemotron runtime Python is unavailable. Run ./scripts/install_release.sh or ./scripts/run_dev.sh to install the managed NeMo runtime."}'
          exit 1
        done
        """

        try wrapper.write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerURL.path)
    }
}

private final class NemotronRunnerProcessSession: NemotronSessionRunning {
    private struct RunnerCommand: Encodable {
        let command: String
        let chunkMilliseconds: Int?
        let samples: [Float]?
    }

    private struct RunnerResponse: Decodable {
        let type: String
        let transcript: String?
        let decodeMilliseconds: Double?
        let message: String?
    }

    private let artifactDirectory: URL
    private let manifest: NemotronArtifactManifest
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(artifactDirectory: URL, manifest: NemotronArtifactManifest) throws {
        self.artifactDirectory = artifactDirectory
        self.manifest = manifest
        let runnerURL = artifactDirectory.appending(path: manifest.runnerExecutableRelativePath)

        process.executableURL = runnerURL
        process.arguments = ["--artifact-dir", artifactDirectory.path]
        process.currentDirectoryURL = artifactDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(configuration: NemotronStreamingConfiguration) throws {
        try process.run()

        let response = try send(
            RunnerCommand(
                command: "start",
                chunkMilliseconds: configuration.chunkMilliseconds,
                samples: nil
            )
        )

        guard response.type == "ready" else {
            throw NemotronBridge.NemotronBridgeError.runnerFailed(
                response.message ?? "The Nemotron English runner did not become ready."
            )
        }
    }

    func appendChunk(samples: [Float]) throws -> StreamingTranscriptionUpdate? {
        guard !samples.isEmpty else { return nil }

        let response = try send(
            RunnerCommand(
                command: "append",
                chunkMilliseconds: nil,
                samples: samples
            )
        )

        guard response.type == "partial" || response.type == "empty" else {
            throw NemotronBridge.NemotronBridgeError.runnerFailed(
                response.message ?? "The Nemotron English runner returned an invalid append response."
            )
        }

        guard let transcript = response.transcript else { return nil }
        return StreamingTranscriptionUpdate(
            transcript: transcript,
            decodeMilliseconds: response.decodeMilliseconds ?? 0
        )
    }

    func finalize(remainingSamples: [Float]) throws -> String {
        let response = try send(
            RunnerCommand(
                command: "finalize",
                chunkMilliseconds: nil,
                samples: remainingSamples
            )
        )

        guard response.type == "final", let transcript = response.transcript else {
            throw NemotronBridge.NemotronBridgeError.runnerFailed(
                response.message ?? "The Nemotron English runner could not finalize the transcript."
            )
        }

        return transcript
    }

    func cancel() {
        if process.isRunning {
            _ = try? send(
                RunnerCommand(
                    command: "cancel",
                    chunkMilliseconds: nil,
                    samples: nil
                )
            )
            process.terminate()
        }
    }

    private func send(_ command: RunnerCommand) throws -> RunnerResponse {
        guard process.isRunning else {
            throw NemotronBridge.NemotronBridgeError.runnerFailed(
                "The Nemotron English runner exited before the session completed."
            )
        }

        let data = try encoder.encode(command) + Data([0x0A])
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        let response = try readNextResponse()

        if response.type == "error" {
            throw NemotronBridge.NemotronBridgeError.runnerFailed(
                response.message ?? "The Nemotron English runner reported an error."
            )
        }

        return response
    }

    private func readNextResponse() throws -> RunnerResponse {
        while true {
            if let newlineRange = stdoutBuffer.range(of: Data([0x0A])) {
                let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)

                guard !line.isEmpty else { continue }
                return try decoder.decode(RunnerResponse.self, from: line)
            }

            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                throw NemotronBridge.NemotronBridgeError.runnerFailed(
                    "The Nemotron English runner closed unexpectedly."
                )
            }

            stdoutBuffer.append(chunk)
        }
    }
}
