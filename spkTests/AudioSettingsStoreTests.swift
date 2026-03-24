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

    func testAutomaticallyCopyTranscriptsPersistsAcrossReload() {
        let store = AudioSettingsStore(userDefaults: userDefaults)
        store.automaticallyCopyTranscripts = false

        let reloadedStore = AudioSettingsStore(userDefaults: userDefaults)

        XCTAssertFalse(reloadedStore.automaticallyCopyTranscripts)
    }
}
