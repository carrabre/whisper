import Foundation

struct WhisperKitStreamingSettingsSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    let customModelFolderPath: String?

    static let disabled = WhisperKitStreamingSettingsSnapshot(
        isEnabled: false,
        customModelFolderPath: nil
    )
}

struct WhisperKitStreamingResolvedModel: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case environment
        case custom
        case bundled
        case appSupport
        case documentsCache

        var description: String {
            switch self {
            case .environment:
                return "developer override"
            case .custom:
                return "selected folder"
            case .bundled:
                return "bundled app model"
            case .appSupport:
                return "installed local model"
            case .documentsCache:
                return "local Hugging Face cache"
            }
        }
    }

    let url: URL
    let source: Source

    var displayName: String {
        url.lastPathComponent
    }
}

enum WhisperKitStreamingModelResolution: Sendable, Equatable {
    case disabled
    case unsupportedHardware
    case ready(WhisperKitStreamingResolvedModel)
    case invalidEnvironmentPath(String)
    case invalidCustomPath(String)
    case missingModel
}

enum WhisperKitStreamingModelLocator {
    static let enabledEnvironmentKey = "SPK_EXPERIMENTAL_WHISPERKIT_STREAMING"
    static let modelPathEnvironmentKey = "SPK_WHISPERKIT_MODEL_PATH"
    static let bundledDirectoryName = "WhisperKitModels"
    private static let supportedModelIdentity = "whisper-medium"

    static func isFeatureRequested(
        environment: [String: String],
        settings: WhisperKitStreamingSettingsSnapshot
    ) -> Bool {
        if let environmentOverride = boolEnvironmentValue(
            key: enabledEnvironmentKey,
            environment: environment
        ) {
            return environmentOverride
        }

        return settings.isEnabled
    }

    static func resolveModel(
        environment: [String: String],
        settings: WhisperKitStreamingSettingsSnapshot,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> WhisperKitStreamingModelResolution {
        guard isFeatureRequested(environment: environment, settings: settings) else {
            return .disabled
        }

        guard isSupportedHardware else {
            return .unsupportedHardware
        }

        var invalidEnvironmentPath: String?
        if let rawPath = normalizedEnvironmentValue(
            key: modelPathEnvironmentKey,
            environment: environment
        ) {
            let environmentURL = URL(fileURLWithPath: rawPath)
            if let resolvedFolder = preferredValidModelFolder(
                startingAt: environmentURL,
                fileManager: fileManager
            ) {
                return .ready(
                    WhisperKitStreamingResolvedModel(
                        url: resolvedFolder,
                        source: .environment
                    )
                )
            }

            invalidEnvironmentPath = rawPath
        }

        var invalidCustomPath: String?
        if let customPath = normalizedPath(settings.customModelFolderPath) {
            let customURL = URL(fileURLWithPath: customPath)
            if let resolvedFolder = preferredValidModelFolder(
                startingAt: customURL,
                fileManager: fileManager
            ) {
                return .ready(
                    WhisperKitStreamingResolvedModel(
                        url: resolvedFolder,
                        source: .custom
                    )
                )
            }

            invalidCustomPath = customPath
        }

        let candidateRoots = knownSearchRoots(bundle: bundle)
        var candidateModels: [WhisperKitStreamingResolvedModel] = []

        for candidateRoot in candidateRoots {
            let resolvedFolders = validModelFolders(
                startingAt: candidateRoot.url,
                fileManager: fileManager
            )

            for resolvedFolder in resolvedFolders {
                candidateModels.append(
                    WhisperKitStreamingResolvedModel(
                        url: resolvedFolder,
                        source: candidateRoot.source
                    )
                )
            }
        }

        if let preferredModel = preferredResolvedModel(from: candidateModels) {
            return .ready(preferredModel)
        }

        if let invalidEnvironmentPath {
            return .invalidEnvironmentPath(invalidEnvironmentPath)
        }

        if let invalidCustomPath {
            return .invalidCustomPath(invalidCustomPath)
        }

        return .missingModel
    }

    static func userFacingSummary(
        environment: [String: String],
        settings: WhisperKitStreamingSettingsSnapshot,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String {
        switch resolveModel(
            environment: environment,
            settings: settings,
            fileManager: fileManager,
            bundle: bundle
        ) {
        case .disabled:
            return "Show partial transcript text while recording. Final transcription still uses Whisper."
        case .unsupportedHardware:
            return "Live preview currently requires Apple Silicon."
        case .ready(let resolvedModel):
            return "Ready with \(resolvedModel.displayName) from the \(resolvedModel.source.description)."
        case .invalidEnvironmentPath(let path):
            return "The developer override model folder is missing: \(path)"
        case .invalidCustomPath(let path):
            return "The selected WhisperKit model folder is missing: \(path)"
        case .missingModel:
            return "Choose or install a local WhisperKit preview model to test live preview."
        }
    }

    private struct SearchRoot: Sendable, Equatable {
        let url: URL
        let source: WhisperKitStreamingResolvedModel.Source
    }

    private static func knownSearchRoots(bundle: Bundle) -> [SearchRoot] {
        var roots: [SearchRoot] = []

        if let bundledURL = bundle.resourceURL?.appending(path: bundledDirectoryName) {
            roots.append(SearchRoot(url: bundledURL, source: .bundled))
        }

        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appending(path: "spk/WhisperKitModels")

        if let appSupportURL {
            roots.append(SearchRoot(url: appSupportURL, source: .appSupport))
        }

        let documentsCacheURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first?.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")

        if let documentsCacheURL {
            roots.append(SearchRoot(url: documentsCacheURL, source: .documentsCache))
        }

        return roots
    }

    private static func preferredValidModelFolder(
        startingAt url: URL,
        fileManager: FileManager,
        depthRemaining: Int = 2
    ) -> URL? {
        preferredModelURL(from: validModelFolders(
            startingAt: url,
            fileManager: fileManager,
            depthRemaining: depthRemaining
        ))
    }

    private static func validModelFolders(
        startingAt url: URL,
        fileManager: FileManager,
        depthRemaining: Int = 2
    ) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        guard directoryExists(at: standardizedURL, fileManager: fileManager) else {
            return []
        }

        var matches: [URL] = []

        if isValidModelFolder(standardizedURL, fileManager: fileManager) {
            matches.append(standardizedURL)
        }

        guard depthRemaining > 0,
              let childDirectories = try? fileManager.contentsOfDirectory(
                at: standardizedURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return matches
        }

        for childURL in childDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard directoryExists(at: childURL, fileManager: fileManager) else {
                continue
            }

            matches.append(contentsOf: validModelFolders(
                startingAt: childURL,
                fileManager: fileManager,
                depthRemaining: depthRemaining - 1
            ))
        }

        return matches
    }

    private static func preferredResolvedModel(
        from candidates: [WhisperKitStreamingResolvedModel]
    ) -> WhisperKitStreamingResolvedModel? {
        candidates.min(by: isPreferredResolvedModel(_:_:))
    }

    private static func preferredModelURL(from candidates: [URL]) -> URL? {
        candidates.min(by: isPreferredModelURL(_:_:))
    }

    private static func isPreferredResolvedModel(
        _ lhs: WhisperKitStreamingResolvedModel,
        _ rhs: WhisperKitStreamingResolvedModel
    ) -> Bool {
        let lhsModelRank = modelPreferenceRank(for: lhs.url)
        let rhsModelRank = modelPreferenceRank(for: rhs.url)
        if lhsModelRank != rhsModelRank {
            return lhsModelRank < rhsModelRank
        }

        let lhsSourceRank = sourcePreferenceRank(lhs.source)
        let rhsSourceRank = sourcePreferenceRank(rhs.source)
        if lhsSourceRank != rhsSourceRank {
            return lhsSourceRank < rhsSourceRank
        }

        return lhs.url.path < rhs.url.path
    }

    private static func isPreferredModelURL(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsRank = modelPreferenceRank(for: lhs)
        let rhsRank = modelPreferenceRank(for: rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.path < rhs.path
    }

    private static func modelPreferenceRank(for url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()

        switch name {
        case let value where value.contains("whisper-medium.en") || value.contains("medium.en"):
            return 0
        case let value where value.contains("whisper-medium") || value.contains("medium"):
            return 1
        default:
            return 50
        }
    }

    private static func sourcePreferenceRank(
        _ source: WhisperKitStreamingResolvedModel.Source
    ) -> Int {
        switch source {
        case .environment:
            return 0
        case .custom:
            return 1
        case .appSupport:
            return 2
        case .documentsCache:
            return 3
        case .bundled:
            return 4
        }
    }

    private static func isValidModelFolder(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isSupportedModelFolder(url, fileManager: fileManager) else {
            return false
        }

        let requiredEntries = [
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "MelSpectrogram.mlmodelc"
        ]

        guard requiredEntries.allSatisfy({
            fileManager.fileExists(atPath: url.appending(path: $0).path)
        }) else {
            return false
        }

        return containsTokenizerJSON(in: url, fileManager: fileManager)
    }

    private static func isSupportedModelFolder(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        if let resolvedIdentity = configuredModelIdentity(in: url, fileManager: fileManager) {
            return resolvedIdentity.contains(supportedModelIdentity)
        }

        return url.lastPathComponent.lowercased().contains(supportedModelIdentity)
    }

    private static func configuredModelIdentity(
        in url: URL,
        fileManager: FileManager
    ) -> String? {
        let candidateConfigURLs = [
            url.appending(path: "config.json"),
            url.appending(path: "models/openai/whisper-medium/config.json")
        ]

        for configURL in candidateConfigURLs {
            guard fileManager.fileExists(atPath: configURL.path),
                  let data = try? Data(contentsOf: configURL),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawIdentity = jsonObject["_name_or_path"] as? String else {
                continue
            }

            return rawIdentity.lowercased()
        }

        return nil
    }

    private static func containsTokenizerJSON(
        in url: URL,
        fileManager: FileManager
    ) -> Bool {
        if fileManager.fileExists(atPath: url.appending(path: "tokenizer.json").path) {
            return true
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let baseDepth = url.pathComponents.count

        for case let candidateURL as URL in enumerator {
            let relativeDepth = candidateURL.pathComponents.count - baseDepth
            if relativeDepth > 5 {
                enumerator.skipDescendants()
                continue
            }

            if candidateURL.lastPathComponent == "tokenizer.json" {
                return true
            }
        }

        return false
    }

    private static func directoryExists(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func normalizedEnvironmentValue(
        key: String,
        environment: [String: String]
    ) -> String? {
        normalizedPath(environment[key])
    }

    private static func normalizedPath(_ rawPath: String?) -> String? {
        guard let rawPath = rawPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else {
            return nil
        }

        return NSString(string: rawPath).expandingTildeInPath
    }

    private static func boolEnvironmentValue(
        key: String,
        environment: [String: String]
    ) -> Bool? {
        guard let rawValue = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty
        else {
            return nil
        }

        if ["1", "true", "yes", "on"].contains(rawValue) {
            return true
        }

        if ["0", "false", "no", "off"].contains(rawValue) {
            return false
        }

        return nil
    }

    private static var isSupportedHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
