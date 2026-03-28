import XCTest
@testable import spk

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

    func testExperimentalStreamingPreviewDefaultsToFalse() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertFalse(store.experimentalStreamingPreviewEnabled)
    }

    func testExperimentalStreamingPreviewDefaultsToTrueWhenLocalModelIsAvailable() throws {
        #if arch(arm64)
        let modelDirectory = temporaryDirectoryURL.appendingPathComponent(
            "openai_whisper-base.en",
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
            .appendingPathComponent("models/openai/whisper-base.en", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tokenizerDirectory,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: tokenizerDirectory.appendingPathComponent("tokenizer.json").path,
            contents: Data("{}".utf8)
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
            string: "~/Models/openai_whisper-base.en"
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

    func testInitRemovesObsoleteTranscriptionKeys() {
        let legacyModeKey = "transcription.mode"
        let legacyProfileKey = "ne" + "motron.latencyProfile"
        userDefaults.set("stale-mode", forKey: legacyModeKey)
        userDefaults.set("stale-profile", forKey: legacyProfileKey)

        _ = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertNil(userDefaults.object(forKey: legacyModeKey))
        XCTAssertNil(userDefaults.object(forKey: legacyProfileKey))
    }

    func testWhisperDescriptionMatchesSingleBackendCopy() {
        XCTAssertEqual(AudioSettingsStore.transcriptionDisplayName, "Whisper")
        XCTAssertTrue(AudioSettingsStore.transcriptionModelName.hasPrefix("whisper-base"))
        XCTAssertTrue(AudioSettingsStore.transcriptionSettingsDescription.contains("never downloads models at runtime"))
    }
}
