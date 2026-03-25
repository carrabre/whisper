import Foundation

struct NemotronArtifactRelease: Codable, Sendable, Equatable {
    let version: String
    let runnerProtocolVersion: String

    private static let fallback = NemotronArtifactRelease(
        version: "2026-03-13",
        runnerProtocolVersion: "1"
    )

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NemotronArtifactRelease {
        var resolvedBase = bundledRelease(bundle: bundle) ?? fallback

        if let overriddenProtocolVersion = environment["SPK_NEMOTRON_RUNNER_PROTOCOL_VERSION"],
           !overriddenProtocolVersion.isEmpty {
            resolvedBase = NemotronArtifactRelease(
                version: resolvedBase.version,
                runnerProtocolVersion: overriddenProtocolVersion
            )
        }

        if let overriddenVersion = environment["SPK_NEMOTRON_ARTIFACT_VERSION"],
           !overriddenVersion.isEmpty {
            return NemotronArtifactRelease(
                version: overriddenVersion,
                runnerProtocolVersion: resolvedBase.runnerProtocolVersion
            )
        }

        return resolvedBase
    }

    var checkpointFileName: String {
        "nemotron-speech-streaming-en-0.6b.nemo"
    }

    func checkpointURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overriddenURL = environment["SPK_NEMOTRON_CHECKPOINT_URL"],
           let resolvedURL = URL(string: overriddenURL) {
            return resolvedURL
        }

        return URL(
            string: "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/main/\(checkpointFileName)"
        )!
    }

    private static func bundledRelease(bundle: Bundle) -> NemotronArtifactRelease? {
        guard let url = bundle.url(
            forResource: "nemotron-artifact-release",
            withExtension: "json",
            subdirectory: "Config"
        ) else {
            return nil
        }

        guard
            let data = try? Data(contentsOf: url),
            let release = try? JSONDecoder().decode(NemotronArtifactRelease.self, from: data)
        else {
            return nil
        }

        return release
    }
}
