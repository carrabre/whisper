import XCTest
@testable import spk

private final class FixedApplicationSupportFileManager: FileManager {
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

@MainActor
final class AudioSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "AudioSettingsStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        userDefaults = nil
        suiteName = nil
        temporaryDirectoryURL = nil
        super.tearDown()
    }

    func testAutomaticallyCopyTranscriptsDefaultsToFalse() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertFalse(store.automaticallyCopyTranscripts)
    }

    func testAllowPasteFallbackDefaultsToTrue() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.allowPasteFallback)
    }

    func testTranscriptionBackendDefaultsToWhisperWhenVoxtralIsUnavailable() {
        let isolatedFileManager = FixedApplicationSupportFileManager(
            applicationSupportRoot: temporaryDirectoryURL
        )
        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            fileManager: isolatedFileManager
        )

        XCTAssertEqual(store.transcriptionBackendSelection, .whisper)
    }

    func testTranscriptionBackendDefaultsToVoxtralRealtimeWhenInstalledModelIsAvailable() throws {
        #if arch(arm64)
        let isolatedFileManager = FixedApplicationSupportFileManager(
            applicationSupportRoot: temporaryDirectoryURL
        )
        _ = try makeVoxtralModelDirectory(
            named: VoxtralRealtimeModelLocator.defaultModelDirectoryName,
            fileManager: isolatedFileManager
        )

        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            fileManager: isolatedFileManager
        )

        XCTAssertEqual(store.transcriptionBackendSelection, .voxtralRealtime)
        #else
        throw XCTSkip("Speed-first Voxtral defaults apply only on supported hardware.")
        #endif
    }

    func testStoredTranscriptionBackendSelectionRemainsAuthoritativeWhenVoxtralIsAvailable() throws {
        #if arch(arm64)
        let isolatedFileManager = FixedApplicationSupportFileManager(
            applicationSupportRoot: temporaryDirectoryURL
        )
        _ = try makeVoxtralModelDirectory(
            named: VoxtralRealtimeModelLocator.defaultModelDirectoryName,
            fileManager: isolatedFileManager
        )
        userDefaults.set(
            TranscriptionBackendSelection.whisper.rawValue,
            forKey: "transcription.backendSelection"
        )

        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            fileManager: isolatedFileManager
        )

        XCTAssertEqual(store.transcriptionBackendSelection, .whisper)
        #else
        throw XCTSkip("Speed-first Voxtral defaults apply only on supported hardware.")
        #endif
    }

    func testEnvironmentBackendSelectionRemainsAuthoritativeWhenVoxtralIsAvailable() throws {
        #if arch(arm64)
        let isolatedFileManager = FixedApplicationSupportFileManager(
            applicationSupportRoot: temporaryDirectoryURL
        )
        _ = try makeVoxtralModelDirectory(
            named: VoxtralRealtimeModelLocator.defaultModelDirectoryName,
            fileManager: isolatedFileManager
        )

        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            environment: [
                VoxtralRealtimeModelLocator.backendSelectionEnvironmentKey: TranscriptionBackendSelection.whisper.rawValue
            ],
            fileManager: isolatedFileManager
        )

        XCTAssertEqual(store.transcriptionBackendSelection, .whisper)
        #else
        throw XCTSkip("Speed-first Voxtral defaults apply only on supported hardware.")
        #endif
    }

    func testExperimentalStreamingPreviewDefaultsToFalse() {
        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            environment: [
                WhisperKitStreamingModelLocator.enabledEnvironmentKey: "0"
            ]
        )

        XCTAssertFalse(store.experimentalStreamingPreviewEnabled)
    }

    func testExperimentalStreamingPreviewDefaultsToTrueWhenLocalModelIsAvailable() throws {
        #if arch(arm64)
        let modelDirectory = temporaryDirectoryURL.appendingPathComponent(
            "openai_whisper-medium",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("MelSpectrogram.mlmodelc"),
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
        userDefaults.set(
            modelDirectory.path,
            forKey: "audio.experimentalStreamingModelFolderPath"
        )

        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.experimentalStreamingPreviewEnabled)
        #else
        throw XCTSkip("Live preview defaults stay off on unsupported hardware.")
        #endif
    }

    func testDiagnosticsEnabledDefaultsToTrue() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.diagnosticsEnabled)
    }

    func testPlayAudioCuesDefaultsToTrue() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.playAudioCues)
    }

    func testSelectedInputDevicePersistsAcrossReload() {
        let availableDevice = AudioDeviceManager().inputDevices().first
        try? XCTSkipIf(availableDevice == nil, "No input devices available on this host.")
        let device = try! XCTUnwrap(availableDevice)

        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.updateSelectedInputDeviceSelection(device.id)

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(reloadedStore.selectedInputDeviceID, device.id)
        XCTAssertEqual(reloadedStore.selectedInputDeviceSelection, device.id)
    }

    func testInputSensitivityClampsAndPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.inputSensitivity = 4.2

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(store.inputSensitivity, AudioSettingsStore.sensitivityRange.upperBound)
        XCTAssertEqual(reloadedStore.inputSensitivity, AudioSettingsStore.sensitivityRange.upperBound)
    }

    func testExperimentalStreamingPreviewSettingPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.experimentalStreamingPreviewEnabled = true

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(reloadedStore.experimentalStreamingPreviewEnabled)
    }

    func testExperimentalStreamingModelFolderPathPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        let expandedPath = NSString(
            string: "~/Models/openai_whisper-medium"
        ).expandingTildeInPath
        store.setExperimentalStreamingModelFolderURL(
            URL(fileURLWithPath: expandedPath)
        )

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(
            reloadedStore.experimentalStreamingModelFolderPath,
            expandedPath
        )
    }

    func testVoxtralRealtimeModelFolderPathPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        let expandedPath = NSString(
            string: "~/Models/Voxtral-Mini-4B-Realtime-2602"
        ).expandingTildeInPath
        store.setVoxtralRealtimeModelFolderURL(
            URL(fileURLWithPath: expandedPath)
        )

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(
            reloadedStore.voxtralRealtimeModelFolderPath,
            expandedPath
        )
    }

    func testTranscriptionBackendSelectionPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.transcriptionBackendSelection = .voxtralRealtime

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(reloadedStore.transcriptionBackendSelection, .voxtralRealtime)
    }

    func testInitRemovesObsoleteTranscriptionKeys() {
        let legacyModeKey = "transcription.mode"
        let legacyProfileKey = "ne" + "motron.latencyProfile"
        userDefaults.set("stale-mode", forKey: legacyModeKey)
        userDefaults.set("stale-profile", forKey: legacyProfileKey)

        _ = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertNil(userDefaults.object(forKey: legacyModeKey))
        XCTAssertNil(userDefaults.object(forKey: legacyProfileKey))
    }

    func testWhisperDescriptionMatchesDefaultBackendCopy() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.transcriptionBackendSelection = .whisper

        XCTAssertEqual(store.transcriptionDisplayName, "Whisper")
        XCTAssertEqual(store.transcriptionModelName, "whisper-base.en-q5_1")
        XCTAssertEqual(store.transcriptionModelSupportedLanguages, "English only")
        XCTAssertTrue(store.transcriptionSettingsDescription.contains("never downloads models at runtime"))
    }

    func testVoxtralDescriptionMatchesRealtimeCopy() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.transcriptionBackendSelection = .voxtralRealtime

        XCTAssertEqual(store.transcriptionDisplayName, "Voxtral Realtime")
        XCTAssertTrue(store.transcriptionModelName.contains("Voxtral-Mini-4B-Realtime-2602"))
        XCTAssertEqual(
            store.transcriptionModelSupportedLanguages,
            "13 languages: Arabic, German, English, Spanish, French, Hindi, Italian, Dutch, Portuguese, Chinese, Japanese, Korean, Russian"
        )
        XCTAssertEqual(
            store.voxtralRealtimeSupportedLanguages,
            "13 languages: Arabic, German, English, Spanish, French, Hindi, Italian, Dutch, Portuguese, Chinese, Japanese, Korean, Russian"
        )
        XCTAssertTrue(store.transcriptionSettingsDescription.contains("fastest local realtime"))
    }

    func testWhisperEnglishOverrideShowsEnglishOnlyLanguageSupport() {
        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            environment: ["SPK_WHISPER_MODEL": "base.en-q5_1"]
        )
        store.transcriptionBackendSelection = .whisper

        XCTAssertEqual(store.transcriptionModelName, "whisper-base.en-q5_1")
        XCTAssertEqual(store.transcriptionModelSupportedLanguages, "English only")
    }

    func testWhisperMultilingualOverrideShowsNinetyNineSupportedLanguages() {
        let store = AudioSettingsStore(
            userDefaults: userDefaults,
            environment: ["SPK_WHISPER_MODEL": "base-q5_1"]
        )
        store.transcriptionBackendSelection = .whisper

        XCTAssertEqual(store.transcriptionModelName, "whisper-base-q5_1")
        XCTAssertEqual(store.transcriptionModelSupportedLanguages, "99 languages")
    }

    func testWhisperKitMediumPreviewModelShowsNinetyNineSupportedLanguages() throws {
        let modelDirectory = try makeWhisperKitModelDirectory(
            named: "openai_whisper-medium",
            tokenizerRepositoryPath: "models/openai/whisper-medium",
            configuredModelIdentity: "openai/whisper-medium"
        )

        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.setExperimentalStreamingModelFolderURL(modelDirectory)

        XCTAssertEqual(store.experimentalStreamingSupportedLanguages, "99 languages")
    }

    func testInvalidWhisperKitPreviewPathFallsBackToBundledPreviewLanguageSummary() {
        let basePath = temporaryDirectoryURL
            .appendingPathComponent("openai_whisper-base.en", isDirectory: true)
            .path
        userDefaults.set(
            true,
            forKey: "audio.experimentalStreamingPreviewEnabled"
        )
        userDefaults.set(
            basePath,
            forKey: "audio.experimentalStreamingModelFolderPath"
        )

        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(store.experimentalStreamingSupportedLanguages, "99 languages")
    }

    private func makeWhisperKitModelDirectory(
        named name: String,
        tokenizerRepositoryPath: String,
        configuredModelIdentity: String
    ) throws -> URL {
        let modelDirectory = temporaryDirectoryURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("MelSpectrogram.mlmodelc"),
            withIntermediateDirectories: true
        )

        let tokenizerDirectory = modelDirectory.appendingPathComponent(
            tokenizerRepositoryPath,
            isDirectory: true
        )
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
            contents: Data(#"{"_name_or_path":"\#(configuredModelIdentity)"}"#.utf8)
        )

        return modelDirectory
    }

    private func makeVoxtralModelDirectory(
        named name: String,
        fileManager: FileManager
    ) throws -> URL {
        let modelDirectory = temporaryDirectoryURL
            .appendingPathComponent("spk/VoxtralModels", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        _ = fileManager.createFile(
            atPath: modelDirectory.appendingPathComponent("config.json").path,
            contents: Data(#"{"_name_or_path":"mistralai/\#(name)"}"#.utf8)
        )
        _ = fileManager.createFile(
            atPath: modelDirectory.appendingPathComponent("preprocessor_config.json").path,
            contents: Data("{}".utf8)
        )
        _ = fileManager.createFile(
            atPath: modelDirectory.appendingPathComponent("tokenizer.json").path,
            contents: Data("{}".utf8)
        )
        _ = fileManager.createFile(
            atPath: modelDirectory.appendingPathComponent("model-00001-of-00001.safetensors").path,
            contents: Data()
        )
        return modelDirectory
    }
}
