import Darwin
import Foundation

struct ManagedRealtimeProvisioningResult: Equatable, Sendable {
    let isManagedBundlePresent: Bool
    let didInstallManagedAssets: Bool
    let didSeedFreshInstallDefaults: Bool
    let didRefreshVoxtralReadinessManifest: Bool

    static let skipped = ManagedRealtimeProvisioningResult(
        isManagedBundlePresent: false,
        didInstallManagedAssets: false,
        didSeedFreshInstallDefaults: false,
        didRefreshVoxtralReadinessManifest: false
    )
}

enum ManagedRealtimeAssetProvisioningError: LocalizedError, Equatable {
    case missingBundleResource(String)
    case invalidWhisperKitPayload(String)
    case invalidVoxtralModelPayload(String)
    case invalidVoxtralRuntimePayload(String)
    case missingBundledHelper
    case failedToInstall(String)
    case failedToPersist(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleResource(let relativePath):
            return "spk is missing the bundled managed realtime asset at \(relativePath). Rebuild the self-contained release payload."
        case .invalidWhisperKitPayload(let relativePath):
            return "spk bundled a WhisperKit payload at \(relativePath), but it is incomplete."
        case .invalidVoxtralModelPayload(let relativePath):
            return "spk bundled a Voxtral model payload at \(relativePath), but it is incomplete."
        case .invalidVoxtralRuntimePayload(let relativePath):
            return "spk bundled a Voxtral runtime payload at \(relativePath), but it is incomplete."
        case .missingBundledHelper:
            return "spk could not find the bundled Voxtral helper script needed for managed provisioning."
        case .failedToInstall(let detail):
            return "spk could not install the bundled realtime assets locally. \(detail)"
        case .failedToPersist(let detail):
            return "spk could not record the managed realtime provisioning state. \(detail)"
        }
    }
}

struct ManagedRealtimeBundleManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let resourceName = "spk_managed_realtime_assets"
    static let resourceExtension = "json"

    let schemaVersion: Int
    let whisperKitModelRelativePath: String
    let whisperKitModelFingerprint: String
    let voxtralModelRelativePath: String
    let voxtralModelFingerprint: String
    let voxtralRuntimeRelativePath: String
    let voxtralRuntimeFingerprint: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case whisperKitModelRelativePath = "whisperkit_model_relative_path"
        case whisperKitModelFingerprint = "whisperkit_model_fingerprint"
        case voxtralModelRelativePath = "voxtral_model_relative_path"
        case voxtralModelFingerprint = "voxtral_model_fingerprint"
        case voxtralRuntimeRelativePath = "voxtral_runtime_relative_path"
        case voxtralRuntimeFingerprint = "voxtral_runtime_fingerprint"
    }

    var identity: String {
        [
            String(schemaVersion),
            whisperKitModelRelativePath,
            whisperKitModelFingerprint,
            voxtralModelRelativePath,
            voxtralModelFingerprint,
            voxtralRuntimeRelativePath,
            voxtralRuntimeFingerprint
        ].joined(separator: "|")
    }
}

private struct ManagedRealtimeInstalledManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let bundleManifestIdentity: String
    let whisperKitModelPath: String
    let voxtralModelPath: String
    let voxtralRuntimePath: String
    let provisionedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleManifestIdentity = "bundle_manifest_identity"
        case whisperKitModelPath = "whisperkit_model_path"
        case voxtralModelPath = "voxtral_model_path"
        case voxtralRuntimePath = "voxtral_runtime_path"
        case provisionedAt = "provisioned_at"
    }
}

struct ManagedRealtimeAssetProvisioner {
    private let bundle: Bundle
    private let fileManager: FileManager
    private let userDefaults: UserDefaults

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.userDefaults = userDefaults
    }

    func provisionIfNeeded() throws -> ManagedRealtimeProvisioningResult {
        guard let bundleManifest = try loadBundleManifest() else {
            return .skipped
        }

        let bundledWhisperKitModelURL = try requiredBundleDirectory(
            relativePath: bundleManifest.whisperKitModelRelativePath,
            validator: { WhisperKitStreamingModelLocator.isValidManagedModelFolder($0, fileManager: fileManager) },
            invalidPayload: { .invalidWhisperKitPayload($0) }
        )
        let bundledVoxtralModelURL = try requiredBundleDirectory(
            relativePath: bundleManifest.voxtralModelRelativePath,
            validator: { VoxtralRealtimeModelLocator.isValidManagedModelFolder($0, fileManager: fileManager) },
            invalidPayload: { .invalidVoxtralModelPayload($0) }
        )
        let bundledVoxtralRuntimeURL = try requiredBundleDirectory(
            relativePath: bundleManifest.voxtralRuntimeRelativePath,
            validator: { VoxtralRealtimeModelLocator.isValidManagedRuntimeDirectory($0, fileManager: fileManager) },
            invalidPayload: { .invalidVoxtralRuntimePayload($0) }
        )
        let bundledHelperURL = try bundledHelperURL()

        let managedWhisperKitURL = WhisperKitStreamingModelLocator.defaultManagedModelDirectory(
            fileManager: fileManager
        )
        let managedVoxtralModelURL = VoxtralRealtimeModelLocator.defaultModelDirectory(
            fileManager: fileManager
        )
        let managedVoxtralRuntimeURL = VoxtralRealtimeModelLocator.defaultManagedRuntimeDirectory(
            fileManager: fileManager
        )
        let managedPythonURL = VoxtralRealtimeModelLocator.defaultPythonURL(fileManager: fileManager)

        let installedManifest = loadInstalledManifest()
        let destinationsMatchInstalledManifest = installedManifest?.bundleManifestIdentity == bundleManifest.identity
            && installedManifest?.whisperKitModelPath == managedWhisperKitURL.standardizedFileURL.path
            && installedManifest?.voxtralModelPath == managedVoxtralModelURL.standardizedFileURL.path
            && installedManifest?.voxtralRuntimePath == managedVoxtralRuntimeURL.standardizedFileURL.path

        let whisperKitReady = WhisperKitStreamingModelLocator.isValidManagedModelFolder(
            managedWhisperKitURL,
            fileManager: fileManager
        )
        let voxtralModelReady = VoxtralRealtimeModelLocator.isValidManagedModelFolder(
            managedVoxtralModelURL,
            fileManager: fileManager
        )
        let voxtralRuntimeReady = VoxtralRealtimeModelLocator.isValidManagedRuntimeDirectory(
            managedVoxtralRuntimeURL,
            fileManager: fileManager
        )

        let shouldCopyManagedAssets = !(destinationsMatchInstalledManifest
            && whisperKitReady
            && voxtralModelReady
            && voxtralRuntimeReady)

        if shouldCopyManagedAssets {
            do {
                try replaceDirectory(at: managedWhisperKitURL, with: bundledWhisperKitModelURL)
                try replaceDirectory(at: managedVoxtralModelURL, with: bundledVoxtralModelURL)
                try replaceDirectory(at: managedVoxtralRuntimeURL, with: bundledVoxtralRuntimeURL)
                try writeInstalledManifest(
                    ManagedRealtimeInstalledManifest(
                        schemaVersion: ManagedRealtimeInstalledManifest.schemaVersion,
                        bundleManifestIdentity: bundleManifest.identity,
                        whisperKitModelPath: managedWhisperKitURL.standardizedFileURL.path,
                        voxtralModelPath: managedVoxtralModelURL.standardizedFileURL.path,
                        voxtralRuntimePath: managedVoxtralRuntimeURL.standardizedFileURL.path,
                        provisionedAt: Date()
                    )
                )
            } catch let provisioningError as ManagedRealtimeAssetProvisioningError {
                throw provisioningError
            } catch {
                throw ManagedRealtimeAssetProvisioningError.failedToInstall(error.localizedDescription)
            }
        }

        let didRefreshVoxtralReadinessManifest: Bool
        switch VoxtralReadinessManifestStore.validateCurrent(
            appBuildVersion: bundleVersionIdentifier(),
            helperURL: bundledHelperURL,
            pythonURL: managedPythonURL,
            modelURL: managedVoxtralModelURL,
            fileManager: fileManager
        ) {
        case .valid(_):
            didRefreshVoxtralReadinessManifest = false
        case .missing, .invalid(_):
            _ = try VoxtralReadinessManifestStore.writeCurrent(
                appBuildVersion: bundleVersionIdentifier(),
                helperURL: bundledHelperURL,
                pythonURL: managedPythonURL,
                modelURL: managedVoxtralModelURL,
                startupMode: .unverified,
                fileManager: fileManager
            )
            didRefreshVoxtralReadinessManifest = true
        }

        let didSeedFreshInstallDefaults = AudioSettingsStore.applyFreshManagedRealtimeDefaultsIfNeeded(
            userDefaults: userDefaults,
            fileManager: fileManager,
            bundle: bundle,
            whisperKitModelFolderPath: managedWhisperKitURL.path,
            voxtralModelFolderPath: managedVoxtralModelURL.path
        )

        return ManagedRealtimeProvisioningResult(
            isManagedBundlePresent: true,
            didInstallManagedAssets: shouldCopyManagedAssets,
            didSeedFreshInstallDefaults: didSeedFreshInstallDefaults,
            didRefreshVoxtralReadinessManifest: didRefreshVoxtralReadinessManifest
        )
    }

    private func loadBundleManifest() throws -> ManagedRealtimeBundleManifest? {
        let manifestURL = bundle.url(
            forResource: ManagedRealtimeBundleManifest.resourceName,
            withExtension: ManagedRealtimeBundleManifest.resourceExtension
        ) ?? bundle.url(
            forResource: ManagedRealtimeBundleManifest.resourceName,
            withExtension: ManagedRealtimeBundleManifest.resourceExtension,
            subdirectory: "Helpers"
        )

        guard let manifestURL else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.managedRealtime.decode(
            ManagedRealtimeBundleManifest.self,
            from: data
        )
        return manifest.schemaVersion == ManagedRealtimeBundleManifest.schemaVersion ? manifest : nil
    }

    private func requiredBundleDirectory(
        relativePath: String,
        validator: (URL) -> Bool,
        invalidPayload: (String) -> ManagedRealtimeAssetProvisioningError
    ) throws -> URL {
        guard let bundleResourcesURL = bundle.resourceURL else {
            throw ManagedRealtimeAssetProvisioningError.missingBundleResource(relativePath)
        }

        let resolvedURL = url(byAppendingRelativePath: relativePath, to: bundleResourcesURL)
        guard fileManager.fileExists(atPath: resolvedURL.path) else {
            throw ManagedRealtimeAssetProvisioningError.missingBundleResource(relativePath)
        }
        guard validator(resolvedURL) else {
            throw invalidPayload(relativePath)
        }

        return resolvedURL
    }

    private func bundledHelperURL() throws -> URL {
        guard let helperURL = bundle.url(
            forResource: "spk_voxtral_realtime_helper",
            withExtension: "py",
            subdirectory: "Helpers"
        ), fileManager.fileExists(atPath: helperURL.path) else {
            throw ManagedRealtimeAssetProvisioningError.missingBundledHelper
        }

        return helperURL
    }

    private func replaceDirectory(at destinationURL: URL, with sourceURL: URL) throws {
        let standardizedDestination = destinationURL.standardizedFileURL
        let parentDirectory = standardizedDestination.deletingLastPathComponent()
        let temporaryDestination = parentDirectory.appending(path: ".tmp-\(UUID().uuidString)-\(standardizedDestination.lastPathComponent)")

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: temporaryDestination.path) {
                try fileManager.removeItem(at: temporaryDestination)
            }
            try copyDirectoryUsingCloneIfPossible(from: sourceURL, to: temporaryDestination)
            if fileManager.fileExists(atPath: standardizedDestination.path) {
                try fileManager.removeItem(at: standardizedDestination)
            }
            try fileManager.moveItem(at: temporaryDestination, to: standardizedDestination)
        } catch {
            if fileManager.fileExists(atPath: temporaryDestination.path) {
                try? fileManager.removeItem(at: temporaryDestination)
            }
            throw ManagedRealtimeAssetProvisioningError.failedToInstall(error.localizedDescription)
        }
    }

    private func copyDirectoryUsingCloneIfPossible(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        guard sourceValues.isDirectory == true else {
            try cloneOrCopyFile(from: sourceURL, to: destinationURL)
            return
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func cloneOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let cloneResult = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }

        if cloneResult == 0 {
            return
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func bundleVersionIdentifier() -> String {
        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        return "\(shortVersion)-\(buildNumber)"
    }

    private func installedManifestURL() -> URL {
        applicationSupportRoot()
            .appending(path: "spk")
            .appending(path: "managed_realtime_assets.json")
    }

    private func loadInstalledManifest() -> ManagedRealtimeInstalledManifest? {
        let manifestURL = installedManifestURL()
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }

        return try? JSONDecoder.managedRealtime.decode(
            ManagedRealtimeInstalledManifest.self,
            from: data
        )
    }

    private func writeInstalledManifest(_ manifest: ManagedRealtimeInstalledManifest) throws {
        let manifestURL = installedManifestURL()

        do {
            try fileManager.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.managedRealtime.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw ManagedRealtimeAssetProvisioningError.failedToPersist(error.localizedDescription)
        }
    }

    private func applicationSupportRoot() -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    private func url(byAppendingRelativePath relativePath: String, to baseURL: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(baseURL) { partialURL, component in
                partialURL.appending(path: String(component))
            }
    }
}

private extension JSONDecoder {
    static let managedRealtime: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let managedRealtime: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
