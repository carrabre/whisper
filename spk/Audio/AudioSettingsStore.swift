import Combine
import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case englishRealtimeNemotron
    case multilingualWhisper

    var id: Self { self }

    var displayName: String {
        switch self {
        case .englishRealtimeNemotron:
            return "English realtime (Nemotron)"
        case .multilingualWhisper:
            return "Multilingual (Whisper)"
        }
    }

    var settingsDescription: String {
        switch self {
        case .englishRealtimeNemotron:
            return "Default English mode. Streams live text and finalizes the transcript with the Nemotron English backend."
        case .multilingualWhisper:
            return "Use this when you want to speak a non-English language. Keeps the current Whisper multilingual pipeline."
        }
    }

    var modelSetupName: String {
        switch self {
        case .englishRealtimeNemotron:
            return "Nemotron English"
        case .multilingualWhisper:
            return "whisper-medium"
        }
    }
}

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let systemDefaultSelectionID = "__system_default__"
    static let sensitivityRange = 0.5...2.5

    private enum DefaultsKey {
        static let transcriptionMode = "transcription.mode"
        static let selectedInputDeviceID = "audio.selectedInputDeviceID"
        static let inputSensitivity = "audio.inputSensitivity"
        static let playAudioCues = "audio.playAudioCues"
        static let automaticallyCopyTranscripts = "transcript.automaticallyCopy"
    }

    @Published var transcriptionMode: TranscriptionMode {
        didSet {
            userDefaults.set(transcriptionMode.rawValue, forKey: DefaultsKey.transcriptionMode)
        }
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
        self.transcriptionMode = Self.persistedTranscriptionMode(from: userDefaults)
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

    private static func persistedTranscriptionMode(from userDefaults: UserDefaults) -> TranscriptionMode {
        guard
            let rawValue = userDefaults.string(forKey: DefaultsKey.transcriptionMode),
            let mode = TranscriptionMode(rawValue: rawValue)
        else {
            return .englishRealtimeNemotron
        }

        return mode
    }
}
