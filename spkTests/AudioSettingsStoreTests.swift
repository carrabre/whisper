import XCTest
@testable import spk

@MainActor
final class AudioSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioSettingsStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAutomaticallyCopyTranscriptsDefaultsToTrue() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.automaticallyCopyTranscripts)
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
        XCTAssertTrue(AudioSettingsStore.transcriptionSettingsDescription.contains("low-latency quantized base model"))
    }
}
