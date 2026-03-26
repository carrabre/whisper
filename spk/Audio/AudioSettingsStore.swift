import Combine
import Foundation

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let systemDefaultSelectionID = "__system_default__"
    static let sensitivityRange = 0.5...2.5
    static let transcriptionDisplayName = "Whisper"
    static let transcriptionModelName = "whisper-medium"
    static let transcriptionSettingsDescription =
        "Whisper uses whisper-medium for local dictation and types into the focused app as your words stabilize."

    private enum DefaultsKey {
        static let legacyTranscriptionMode = "transcription.mode"
        static let legacyProfileKey = "ne" + "motron.latencyProfile"
        static let selectedInputDeviceID = "audio.selectedInputDeviceID"
        static let inputSensitivity = "audio.inputSensitivity"
        static let playAudioCues = "audio.playAudioCues"
        static let automaticallyCopyTranscripts = "transcript.automaticallyCopy"
    }

    @Published var selectedInputDeviceID: String? {
        didSet {
            persistSelectedInputDevice()
        }
    }

    @Published var inputSensitivity: Double {
        didSet {
            let clampedValue = Self.clampSensitivity(inputSensitivity)
            if clampedValue != inputSensitivity {
                inputSensitivity = clampedValue
                return
            }

            userDefaults.set(inputSensitivity, forKey: DefaultsKey.inputSensitivity)
        }
    }

    @Published var automaticallyCopyTranscripts: Bool {
        didSet {
            userDefaults.set(automaticallyCopyTranscripts, forKey: DefaultsKey.automaticallyCopyTranscripts)
        }
    }

    @Published var playAudioCues: Bool {
        didSet {
            userDefaults.set(playAudioCues, forKey: DefaultsKey.playAudioCues)
        }
    }

    @Published private(set) var availableInputDevices: [AudioInputDevice] = []

    private let userDefaults: UserDefaults
    private let audioDeviceManager: AudioDeviceManager

    init(
        userDefaults: UserDefaults = .standard,
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager()
    ) {
        self.userDefaults = userDefaults
        self.audioDeviceManager = audioDeviceManager
        Self.removeObsoleteTranscriptionDefaults(from: userDefaults)
        self.selectedInputDeviceID = userDefaults.string(forKey: DefaultsKey.selectedInputDeviceID)
        self.inputSensitivity = Self.clampSensitivity(
            userDefaults.object(forKey: DefaultsKey.inputSensitivity) as? Double ?? 1.0
        )
        self.automaticallyCopyTranscripts = userDefaults.object(forKey: DefaultsKey.automaticallyCopyTranscripts) as? Bool ?? true
        self.playAudioCues = userDefaults.object(forKey: DefaultsKey.playAudioCues) as? Bool ?? true

        refreshInputDevices()
    }

    var selectedInputDeviceSelection: String {
        selectedInputDeviceID ?? Self.systemDefaultSelectionID
    }

    var defaultInputDeviceName: String {
        audioDeviceManager.defaultInputDeviceName() ?? "Current macOS default"
    }

    var selectedInputDeviceName: String {
        if let selectedInputDeviceID,
           let matchingDevice = availableInputDevices.first(where: { $0.id == selectedInputDeviceID }) {
            return matchingDevice.name
        }

        return defaultInputDeviceName
    }

    var sensitivityDisplay: String {
        String(format: "%.1fx", inputSensitivity)
    }

    func updateSelectedInputDeviceSelection(_ selection: String) {
        let resolvedSelection = selection == Self.systemDefaultSelectionID ? nil : selection
        selectedInputDeviceID = resolvedSelection
    }

    func refreshInputDevices() {
        availableInputDevices = audioDeviceManager.inputDevices()

        if let selectedInputDeviceID,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            self.selectedInputDeviceID = nil
        }
    }

    private func persistSelectedInputDevice() {
        if let selectedInputDeviceID {
            userDefaults.set(selectedInputDeviceID, forKey: DefaultsKey.selectedInputDeviceID)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.selectedInputDeviceID)
        }
    }

    private static func clampSensitivity(_ value: Double) -> Double {
        min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    private static func removeObsoleteTranscriptionDefaults(from userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: DefaultsKey.legacyTranscriptionMode)
        userDefaults.removeObject(forKey: DefaultsKey.legacyProfileKey)
    }
}
