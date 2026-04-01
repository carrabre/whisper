import CryptoKit
import Foundation

struct VoxtralRealtimeSettingsSnapshot: Sendable, Equatable {
    let customModelFolderPath: String?
}

struct VoxtralRealtimeResolvedModel: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case environment
        case custom
        case appSupport

        var description: String {
            switch self {
            case .environment:
                return "developer override"
            case .custom:
                return "selected folder"
            case .appSupport:
                return "installed local model"
            }
        }
    }

    let url: URL
    let source: Source

    var displayName: String {
        url.lastPathComponent
    }
}

enum VoxtralRealtimeModelResolution: Sendable, Equatable {
    case unsupportedHardware
    case ready(VoxtralRealtimeResolvedModel)
    case invalidEnvironmentPath(String)
    case invalidCustomPath(String)
    case missingModel
}

enum VoxtralRealtimeHelperResolution: Sendable, Equatable {
    case ready(URL)
    case invalidEnvironmentPath(String)
    case missingHelper
}

enum VoxtralRealtimePythonResolution: Sendable, Equatable {
    case ready(URL)
    case invalidEnvironmentPath(String)
    case missingPreferredRuntime
}

enum VoxtralRealtimeModelLocator {
    static let modelPathEnvironmentKey = "SPK_VOXTRAL_REALTIME_MODEL_PATH"
    static let helperPathEnvironmentKey = "SPK_VOXTRAL_REALTIME_HELPER_PATH"
    static let pythonPathEnvironmentKey = "SPK_VOXTRAL_REALTIME_PYTHON_PATH"
    static let backendSelectionEnvironmentKey = "SPK_TRANSCRIPTION_BACKEND"
    static let defaultModelDirectoryName = "Voxtral-Mini-4B-Realtime-2602"

    static func resolveModel(
        environment: [String: String],
        settings: VoxtralRealtimeSettingsSnapshot,
        fileManager: FileManager = .default
    ) -> VoxtralRealtimeModelResolution {
        guard isSupportedHardware else {
            return .unsupportedHardware
        }

        var invalidEnvironmentPath: String?
        if let rawPath = normalizedEnvironmentValue(
            key: modelPathEnvironmentKey,
            environment: environment
        ) {
            let environmentURL = URL(fileURLWithPath: rawPath)
            if isValidModelFolder(environmentURL, fileManager: fileManager) {
                return .ready(VoxtralRealtimeResolvedModel(url: environmentURL, source: .environment))
            }
            invalidEnvironmentPath = rawPath
        }

        var invalidCustomPath: String?
        if let customPath = normalizedPath(settings.customModelFolderPath) {
            let customURL = URL(fileURLWithPath: customPath)
            if isValidModelFolder(customURL, fileManager: fileManager) {
                return .ready(VoxtralRealtimeResolvedModel(url: customURL, source: .custom))
            }
            invalidCustomPath = customPath
        }

        let appSupportDirectory = defaultModelDirectory(fileManager: fileManager)
        if isValidModelFolder(appSupportDirectory, fileManager: fileManager) {
            return .ready(VoxtralRealtimeResolvedModel(url: appSupportDirectory, source: .appSupport))
        }

        if let invalidEnvironmentPath {
            return .invalidEnvironmentPath(invalidEnvironmentPath)
        }

        if let invalidCustomPath {
            return .invalidCustomPath(invalidCustomPath)
        }

        return .missingModel
    }

    static func resolveHelper(
        environment: [String: String],
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> VoxtralRealtimeHelperResolution {
        if let rawPath = normalizedEnvironmentValue(
            key: helperPathEnvironmentKey,
            environment: environment
        ) {
            let helperURL = URL(fileURLWithPath: rawPath)
            return fileManager.fileExists(atPath: helperURL.path)
                ? .ready(helperURL)
                : .invalidEnvironmentPath(rawPath)
        }

        if let bundledURL = bundle.url(
            forResource: "spk_voxtral_realtime_helper",
            withExtension: "py",
            subdirectory: "Helpers"
        ), fileManager.fileExists(atPath: bundledURL.path) {
            return .ready(bundledURL)
        }

        return .missingHelper
    }

    static func resolvePython(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> VoxtralRealtimePythonResolution {
        if let rawPath = normalizedEnvironmentValue(
            key: pythonPathEnvironmentKey,
            environment: environment
        ) {
            let pythonURL = URL(fileURLWithPath: rawPath)
            return fileManager.isExecutableFile(atPath: pythonURL.path)
                ? .ready(pythonURL)
                : .invalidEnvironmentPath(rawPath)
        }

        let bundledRuntimeURL = defaultPythonURL(fileManager: fileManager)
        if fileManager.isExecutableFile(atPath: bundledRuntimeURL.path) {
            return .ready(bundledRuntimeURL)
        }

        return .missingPreferredRuntime
    }

    static func userFacingSummary(
        environment: [String: String],
        settings: VoxtralRealtimeSettingsSnapshot,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String {
        let modelResolution = resolveModel(
            environment: environment,
            settings: settings,
            fileManager: fileManager
        )
        let helperResolution = resolveHelper(
            environment: environment,
            bundle: bundle,
            fileManager: fileManager
        )

        switch modelResolution {
        case .unsupportedHardware:
            return "Voxtral Realtime currently requires Apple Silicon."
        case .invalidEnvironmentPath(let path):
            return "The developer override Voxtral model folder is missing: \(path)"
        case .invalidCustomPath(let path):
            return "The selected Voxtral model folder is missing: \(path)"
        case .missingModel:
            return "Choose or install a local Voxtral Realtime model folder to enable this backend."
        case .ready(let resolvedModel):
            switch helperResolution {
            case .ready:
                return "Ready with \(resolvedModel.displayName) from the \(resolvedModel.source.description)."
            case .invalidEnvironmentPath(let path):
                return "The developer override Voxtral helper is missing: \(path)"
            case .missingHelper:
                return "The Voxtral model is available, but the local helper script is not bundled yet."
            }
        }
    }

    static func defaultModelDirectory(fileManager: FileManager = .default) -> URL {
        defaultAppSupportRoot(fileManager: fileManager)
            .appending(path: "spk/VoxtralModels")
            .appending(path: defaultModelDirectoryName)
    }

    static func defaultRuntimeDirectory(fileManager: FileManager = .default) -> URL {
        defaultAppSupportRoot(fileManager: fileManager)
            .appending(path: "spk/VoxtralRuntime")
    }

    static func defaultReadinessManifestURL(fileManager: FileManager = .default) -> URL {
        defaultRuntimeDirectory(fileManager: fileManager)
            .appending(path: "readiness.json")
    }

    private static func defaultAppSupportRoot(fileManager: FileManager) -> URL {
        let appSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return appSupportRoot
    }

    static func defaultPythonURL(fileManager: FileManager = .default) -> URL {
        return defaultRuntimeDirectory(fileManager: fileManager)
            .appending(path: "py312/bin")
            .appending(path: "python")
    }

    private static var isSupportedHardware: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func isValidModelFolder(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        let configURL = standardizedURL.appending(path: "config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return false
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: standardizedURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let hasWeights = children.contains { child in
            let name = child.lastPathComponent.lowercased()
            return name.hasSuffix(".safetensors") || name.hasPrefix("model-") || name.hasPrefix("pytorch_model")
        }
        let hasProcessorConfig = fileManager.fileExists(
            atPath: standardizedURL.appending(path: "preprocessor_config.json").path
        ) || fileManager.fileExists(
            atPath: standardizedURL.appending(path: "processor_config.json").path
        )
        let hasTokenizer = fileManager.fileExists(
            atPath: standardizedURL.appending(path: "tokenizer.json").path
        ) || fileManager.fileExists(
            atPath: standardizedURL.appending(path: "tokenizer.model").path
        ) || fileManager.fileExists(
            atPath: standardizedURL.appending(path: "tekken.json").path
        )

        return hasWeights && hasProcessorConfig && hasTokenizer
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
}

struct VoxtralReadinessManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let appBuildVersion: String
    let helperPath: String
    let helperFingerprint: String
    let pythonPath: String
    let pythonVersion: String
    let modelPath: String
    let modelFingerprint: String
    let preflightedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appBuildVersion = "app_build_version"
        case helperPath = "helper_path"
        case helperFingerprint = "helper_fingerprint"
        case pythonPath = "python_path"
        case pythonVersion = "python_version"
        case modelPath = "model_path"
        case modelFingerprint = "model_fingerprint"
        case preflightedAt = "preflighted_at"
    }
}

enum VoxtralReadinessManifestStatus: Equatable, Sendable {
    case valid
    case missing
    case invalid(String)
}

enum VoxtralReadinessManifestStore {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func manifestURL(fileManager: FileManager = .default) -> URL {
        VoxtralRealtimeModelLocator.defaultReadinessManifestURL(fileManager: fileManager)
    }

    static func load(
        manifestURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> VoxtralReadinessManifest? {
        let url = manifestURL ?? self.manifestURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(VoxtralReadinessManifest.self, from: data)
    }

    static func validateCurrent(
        appBuildVersion: String,
        helperURL: URL,
        pythonURL: URL,
        modelURL: URL,
        manifestURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> VoxtralReadinessManifestStatus {
        guard let manifest = load(manifestURL: manifestURL, fileManager: fileManager) else {
            return .missing
        }

        guard manifest.schemaVersion == VoxtralReadinessManifest.schemaVersion else {
            return .invalid("schema version changed")
        }
        guard manifest.appBuildVersion == appBuildVersion else {
            return .invalid("app build changed")
        }

        do {
            let helperPath = helperURL.standardizedFileURL.path
            let currentHelperFingerprint = try helperFingerprint(helperURL)
            guard manifest.helperPath == helperPath else {
                return .invalid("helper path changed")
            }
            guard manifest.helperFingerprint == currentHelperFingerprint else {
                return .invalid("helper fingerprint changed")
            }

            let pythonPath = pythonURL.standardizedFileURL.path
            let currentPythonVersion = try pythonVersion(pythonURL)
            guard manifest.pythonPath == pythonPath else {
                return .invalid("python path changed")
            }
            guard manifest.pythonVersion == currentPythonVersion else {
                return .invalid("python version changed")
            }

            let modelPath = modelURL.standardizedFileURL.path
            let currentModelFingerprint = try modelFingerprint(modelURL, fileManager: fileManager)
            guard manifest.modelPath == modelPath else {
                return .invalid("model path changed")
            }
            guard manifest.modelFingerprint == currentModelFingerprint else {
                return .invalid("model fingerprint changed")
            }

            return .valid
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    @discardableResult
    static func writeCurrent(
        appBuildVersion: String,
        helperURL: URL,
        pythonURL: URL,
        modelURL: URL,
        manifestURL: URL? = nil,
        fileManager: FileManager = .default,
        date: Date = Date()
    ) throws -> VoxtralReadinessManifest {
        let manifest = VoxtralReadinessManifest(
            schemaVersion: VoxtralReadinessManifest.schemaVersion,
            appBuildVersion: appBuildVersion,
            helperPath: helperURL.standardizedFileURL.path,
            helperFingerprint: try helperFingerprint(helperURL),
            pythonPath: pythonURL.standardizedFileURL.path,
            pythonVersion: try pythonVersion(pythonURL),
            modelPath: modelURL.standardizedFileURL.path,
            modelFingerprint: try modelFingerprint(modelURL, fileManager: fileManager),
            preflightedAt: date
        )

        let resolvedManifestURL = manifestURL ?? self.manifestURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: resolvedManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encoder.encode(manifest)
        try data.write(to: resolvedManifestURL, options: .atomic)
        return manifest
    }

    static func helperFingerprint(_ helperURL: URL) throws -> String {
        let data = try Data(contentsOf: helperURL)
        return sha256Hex(of: data)
    }

    static func pythonVersion(_ pythonURL: URL) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = pythonURL
        process.arguments = ["--version"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let version = (output + error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !version.isEmpty else {
            throw NSError(
                domain: "VoxtralReadinessManifestStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine the Voxtral Python runtime version."]
            )
        }
        return version
    }

    static func modelFingerprint(
        _ modelURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: modelURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "VoxtralReadinessManifestStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not inspect the Voxtral model directory."]
            )
        }

        var entries: [String] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(
                of: modelURL.standardizedFileURL.path + "/",
                with: ""
            )
            let size = resourceValues.fileSize ?? 0
            let modificationTime = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries.append("\(relativePath)|\(size)|\(Int64(modificationTime * 1_000_000_000))")
        }

        entries.sort()
        return sha256Hex(of: Data(entries.joined(separator: "\n").utf8))
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
