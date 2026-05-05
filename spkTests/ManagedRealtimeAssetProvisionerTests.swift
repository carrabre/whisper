import Foundation
import XCTest
@testable import spk

private final class ManagedProvisioningFileManager: FileManager {
    private let applicationSupportRoot: URL

    init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask == .userDomainMask {
            return [applicationSupportRoot]
        }

        return super.urls(for: directory, in: domainMask)
    }
}

final class ManagedRealtimeAssetProvisionerTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var temporaryDirectoryURL: URL!
    private var applicationSupportURL: URL!
    private var fileManager: ManagedProvisioningFileManager!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedRealtimeAssetProvisionerTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        applicationSupportURL = temporaryDirectoryURL.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        fileManager = ManagedProvisioningFileManager(applicationSupportRoot: applicationSupportURL)
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        fileManager = nil
        applicationSupportURL = nil
        temporaryDirectoryURL = nil
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testProvisionerCopiesManagedAssetsAndSeedsFreshDefaults() throws {
        let bundle = try makeFixtureBundle()
        let provisioner = ManagedRealtimeAssetProvisioner(
            bundle: bundle,
            fileManager: fileManager,
            userDefaults: userDefaults
        )

        let result = try provisioner.provisionIfNeeded()

        XCTAssertTrue(result.isManagedBundlePresent)
        XCTAssertTrue(result.didInstallManagedAssets)
        XCTAssertTrue(result.didRefreshVoxtralReadinessManifest)
        XCTAssertTrue(result.didSeedFreshInstallDefaults)
        XCTAssertTrue(
            WhisperKitStreamingModelLocator.isValidManagedModelFolder(
                WhisperKitStreamingModelLocator.defaultManagedModelDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
        )
        XCTAssertTrue(
            VoxtralRealtimeModelLocator.isValidManagedModelFolder(
                VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
        )
        XCTAssertTrue(
            VoxtralRealtimeModelLocator.isValidManagedRuntimeDirectory(
                VoxtralRealtimeModelLocator.defaultManagedRuntimeDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
        )
        XCTAssertEqual(
            userDefaults.string(forKey: "audio.experimentalStreamingModelFolderPath"),
            WhisperKitStreamingModelLocator.defaultManagedModelDirectory(fileManager: fileManager).path
        )
        XCTAssertEqual(
            userDefaults.string(forKey: "audio.voxtralRealtimeModelFolderPath"),
            VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager).path
        )
        #if arch(arm64)
        XCTAssertEqual(
            userDefaults.string(forKey: "transcription.backendSelection"),
            TranscriptionBackendSelection.voxtralRealtime.rawValue
        )
        XCTAssertEqual(
            userDefaults.object(forKey: "audio.experimentalStreamingPreviewEnabled") as? Bool,
            true
        )
        #else
        XCTAssertNil(userDefaults.string(forKey: "transcription.backendSelection"))
        XCTAssertNil(userDefaults.object(forKey: "audio.experimentalStreamingPreviewEnabled"))
        #endif

        let readinessManifest = VoxtralReadinessManifestStore.load(fileManager: fileManager)
        XCTAssertEqual(
            readinessManifest?.modelPath,
            VoxtralRealtimeModelLocator.defaultModelDirectory(fileManager: fileManager).path
        )
        XCTAssertEqual(
            readinessManifest?.pythonPath,
            VoxtralRealtimeModelLocator.defaultPythonURL(fileManager: fileManager).path
        )
        XCTAssertEqual(readinessManifest?.startupMode, .unverified)
    }

    func testProvisionerPreservesExistingUserPreferences() throws {
        let bundle = try makeFixtureBundle()
        userDefaults.set(
            TranscriptionBackendSelection.whisper.rawValue,
            forKey: "transcription.backendSelection"
        )
        userDefaults.set(
            false,
            forKey: "audio.experimentalStreamingPreviewEnabled"
        )
        userDefaults.set(
            "/tmp/custom-whisperkit",
            forKey: "audio.experimentalStreamingModelFolderPath"
        )
        userDefaults.set(
            "/tmp/custom-voxtral",
            forKey: "audio.voxtralRealtimeModelFolderPath"
        )
        let provisioner = ManagedRealtimeAssetProvisioner(
            bundle: bundle,
            fileManager: fileManager,
            userDefaults: userDefaults
        )

        let result = try provisioner.provisionIfNeeded()

        XCTAssertTrue(result.didInstallManagedAssets)
        XCTAssertFalse(result.didSeedFreshInstallDefaults)
        XCTAssertEqual(
            userDefaults.string(forKey: "transcription.backendSelection"),
            TranscriptionBackendSelection.whisper.rawValue
        )
        XCTAssertEqual(
            userDefaults.object(forKey: "audio.experimentalStreamingPreviewEnabled") as? Bool,
            false
        )
        XCTAssertEqual(
            userDefaults.string(forKey: "audio.experimentalStreamingModelFolderPath"),
            "/tmp/custom-whisperkit"
        )
        XCTAssertEqual(
            userDefaults.string(forKey: "audio.voxtralRealtimeModelFolderPath"),
            "/tmp/custom-voxtral"
        )
    }

    func testProvisionerRepairsMissingManagedAssetsOnSubsequentRun() throws {
        let bundle = try makeFixtureBundle()
        let provisioner = ManagedRealtimeAssetProvisioner(
            bundle: bundle,
            fileManager: fileManager,
            userDefaults: userDefaults
        )

        _ = try provisioner.provisionIfNeeded()
        try FileManager.default.removeItem(
            at: VoxtralRealtimeModelLocator.defaultManagedRuntimeDirectory(fileManager: fileManager)
        )

        let result = try provisioner.provisionIfNeeded()

        XCTAssertTrue(result.didInstallManagedAssets)
        XCTAssertTrue(
            VoxtralRealtimeModelLocator.isValidManagedRuntimeDirectory(
                VoxtralRealtimeModelLocator.defaultManagedRuntimeDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
        )
    }

    func testProvisionerFailsWhenManagedBundleManifestReferencesMissingRuntime() throws {
        let bundle = try makeFixtureBundle(includeVoxtralRuntime: false)
        let provisioner = ManagedRealtimeAssetProvisioner(
            bundle: bundle,
            fileManager: fileManager,
            userDefaults: userDefaults
        )

        XCTAssertThrowsError(try provisioner.provisionIfNeeded()) { error in
            XCTAssertEqual(
                error as? ManagedRealtimeAssetProvisioningError,
                .missingBundleResource("VoxtralRuntime/py312")
            )
        }
    }

    private func makeFixtureBundle(
        includeWhisperKit: Bool = true,
        includeVoxtralModel: Bool = true,
        includeVoxtralRuntime: Bool = true
    ) throws -> Bundle {
        let bundleURL = temporaryDirectoryURL.appendingPathComponent("Fixture.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let helpersURL = resourcesURL.appendingPathComponent("Helpers", isDirectory: true)

        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.acfinc.spk.tests.fixture</string>
            <key>CFBundleVersion</key>
            <string>7</string>
            <key>CFBundleShortVersionString</key>
            <string>2.0</string>
            <key>CFBundleExecutable</key>
            <string>spk</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        let helperURL = helpersURL.appendingPathComponent(
            "spk_voxtral_realtime_helper.py"
        )
        try "print('helper ready')\n".write(
            to: helperURL,
            atomically: true,
            encoding: .utf8
        )
        let executableURL = macOSURL.appendingPathComponent("spk")
        try "#!/bin/sh\nexit 0\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )

        if includeWhisperKit {
            try makeWhisperKitModel(
                at: resourcesURL
                    .appendingPathComponent("WhisperKitModels", isDirectory: true)
                    .appendingPathComponent("openai_whisper-medium", isDirectory: true)
            )
        }

        if includeVoxtralModel {
            try makeVoxtralModel(
                at: resourcesURL
                    .appendingPathComponent("VoxtralModels", isDirectory: true)
                    .appendingPathComponent(
                        VoxtralRealtimeModelLocator.defaultModelDirectoryName,
                        isDirectory: true
                    )
            )
        }

        if includeVoxtralRuntime {
            try makeVoxtralRuntime(
                at: resourcesURL
                    .appendingPathComponent("VoxtralRuntime", isDirectory: true)
                    .appendingPathComponent("py312", isDirectory: true)
            )
        }

        let bundleManifest = ManagedRealtimeBundleManifest(
            schemaVersion: ManagedRealtimeBundleManifest.schemaVersion,
            whisperKitModelRelativePath: "WhisperKitModels/openai_whisper-medium",
            whisperKitModelFingerprint: "whisperkit-fingerprint",
            voxtralModelRelativePath: "VoxtralModels/\(VoxtralRealtimeModelLocator.defaultModelDirectoryName)",
            voxtralModelFingerprint: "voxtral-model-fingerprint",
            voxtralRuntimeRelativePath: "VoxtralRuntime/py312",
            voxtralRuntimeFingerprint: "voxtral-runtime-fingerprint"
        )
        let bundleManifestURL = helpersURL.appendingPathComponent(
            "\(ManagedRealtimeBundleManifest.resourceName).\(ManagedRealtimeBundleManifest.resourceExtension)"
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.dateEncodingStrategy = .iso8601
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try manifestEncoder.encode(bundleManifest)
        try manifestData.write(to: bundleManifestURL)

        guard let bundle = Bundle(url: bundleURL) else {
            throw NSError(
                domain: "ManagedRealtimeAssetProvisionerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open the fixture bundle."]
            )
        }

        return bundle
    }

    private func makeWhisperKitModel(at modelDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("MelSpectrogram.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        let tokenizerDirectory = modelDirectory
            .appendingPathComponent("models/openai/whisper-medium", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tokenizerDirectory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: tokenizerDirectory.appendingPathComponent("tokenizer.json").path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: modelDirectory.appendingPathComponent("config.json").path,
            contents: Data(#"{"_name_or_path":"openai/whisper-medium"}"#.utf8)
        )
    }

    private func makeVoxtralModel(at modelDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: modelDirectory.appendingPathComponent("config.json").path,
            contents: Data(#"{"model_type":"voxtral"}"#.utf8)
        )
        _ = FileManager.default.createFile(
            atPath: modelDirectory.appendingPathComponent("processor_config.json").path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: modelDirectory.appendingPathComponent("tokenizer.json").path,
            contents: Data("{}".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: modelDirectory.appendingPathComponent("model-00001-of-00001.safetensors").path,
            contents: Data("weights".utf8)
        )
    }

    private func makeVoxtralRuntime(at runtimeDirectory: URL) throws {
        let binDirectory = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        let pythonURL = binDirectory.appendingPathComponent("python")
        try """
        #!/bin/sh
        echo "Python 3.12.8"
        """.write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: pythonURL.path
        )
        let packageDirectory = runtimeDirectory
            .appendingPathComponent("lib/python3.12/site-packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageDirectory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: packageDirectory.appendingPathComponent("placeholder.txt").path,
            contents: Data("runtime".utf8)
        )
    }
}
