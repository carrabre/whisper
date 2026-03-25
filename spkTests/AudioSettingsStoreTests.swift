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

    func testTranscriptionModeDefaultsToEnglishRealtimeNemotron() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(store.transcriptionMode, .englishRealtimeNemotron)
    }

    func testTranscriptionModePersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.transcriptionMode = .multilingualWhisper

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(reloadedStore.transcriptionMode, .multilingualWhisper)
    }

    func testAutomaticallyCopyTranscriptsPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.automaticallyCopyTranscripts = false

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertFalse(reloadedStore.automaticallyCopyTranscripts)
    }

    func testPlayAudioCuesDefaultsToTrue() {
        let store = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertTrue(store.playAudioCues)
    }

    func testPlayAudioCuesPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.playAudioCues = false

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertFalse(reloadedStore.playAudioCues)
    }
}
