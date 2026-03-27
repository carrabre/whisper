import Combine
import Foundation

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let systemDefaultSelectionID = "__system_default__"
    static let sensitivityRange = 0.5...2.5
    static let transcriptionDisplayName = "Whisper"
    static var transcriptionModelName: String {
        WhisperBridge.defaultModelDisplayName
    }
    static let transcriptionSettingsDescription =
        "Whisper uses only bundled or locally installed model files for dictation on this Mac. The app never downloads models at runtime."

    private enum DefaultsKey {
        static let legacyTranscriptionMode = "transcription.mode"
        static let legacyProfileKey = "ne" + "motron.latencyProfile"
        static let selectedInputDeviceID = "audio.selectedInputDeviceID"
        static let inputSensitivity = "audio.inputSensitivity"
        static let experimentalStreamingPreviewEnabled = "audio.experimentalStreamingPreviewEnabled"
        static let experimentalStreamingModelFolderPath = "audio.experimentalStreamingModelFolderPath"
        static let playAudioCues = "audio.playAudioCues"
        static let automaticallyCopyTranscripts = "transcript.automaticallyCopy"
        static let allowPasteFallback = "transcript.allowPasteFallback"
        static let diagnosticsEnabled = "diagnostics.enabled"
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

    @Published var experimentalStreamingPreviewEnabled: Bool {
        didSet {
            userDefaults.set(
                experimentalStreamingPreviewEnabled,
                forKey: DefaultsKey.experimentalStreamingPreviewEnabled
            )
        }
    }

    @Published var experimentalStreamingModelFolderPath: String? {
        didSet {
            persistExperimentalStreamingModelFolderPath()
        }
    }

    @Published var automaticallyCopyTranscripts: Bool {
        didSet {
            userDefaults.set(automaticallyCopyTranscripts, forKey: DefaultsKey.automaticallyCopyTranscripts)
        }
    }

    @Published var allowPasteFallback: Bool {
        didSet {
            userDefaults.set(allowPasteFallback, forKey: DefaultsKey.allowPasteFallback)
        }
    }

    @Published var playAudioCues: Bool {
        didSet {
            userDefaults.set(playAudioCues, forKey: DefaultsKey.playAudioCues)
        }
    }

    @Published var diagnosticsEnabled: Bool {
        didSet {
            userDefaults.set(diagnosticsEnabled, forKey: DefaultsKey.diagnosticsEnabled)
            DebugLog.setCollectionEnabled(diagnosticsEnabled)
            if diagnosticsEnabled {
                DebugLog.startSession()
            }
        }
    }

    @Published private(set) var availableInputDevices: [AudioInputDevice] = []

    private let userDefaults: UserDefaults
    private let audioDeviceManager: AudioDeviceManager
    private let environment: [String: String]
    private let fileManager: FileManager
    private let bundle: Bundle

    init(
        userDefaults: UserDefaults = .standard,
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) {
        self.userDefaults = userDefaults
        self.audioDeviceManager = audioDeviceManager
        self.environment = environment
        self.fileManager = fileManager
        self.bundle = bundle
        Self.removeObsoleteTranscriptionDefaults(from: userDefaults)
        self.selectedInputDeviceID = userDefaults.string(forKey: DefaultsKey.selectedInputDeviceID)
        self.inputSensitivity = Self.clampSensitivity(
            userDefaults.object(forKey: DefaultsKey.inputSensitivity) as? Double ?? 1.0
        )
        let initialExperimentalStreamingModelFolderPath = Self.normalizePath(
            userDefaults.string(forKey: DefaultsKey.experimentalStreamingModelFolderPath)
        )
        self.experimentalStreamingModelFolderPath = initialExperimentalStreamingModelFolderPath
        self.experimentalStreamingPreviewEnabled = Self.defaultExperimentalStreamingPreviewEnabled(
            userDefaults: userDefaults,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle,
            customModelFolderPath: initialExperimentalStreamingModelFolderPath
        )
        self.automaticallyCopyTranscripts = userDefaults.object(forKey: DefaultsKey.automaticallyCopyTranscripts) as? Bool ?? false
        self.allowPasteFallback = userDefaults.object(forKey: DefaultsKey.allowPasteFallback) as? Bool ?? false
        self.playAudioCues = userDefaults.object(forKey: DefaultsKey.playAudioCues) as? Bool ?? true
        self.diagnosticsEnabled = userDefaults.object(forKey: DefaultsKey.diagnosticsEnabled) as? Bool ?? true
        DebugLog.setCollectionEnabled(self.diagnosticsEnabled)

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

    var experimentalStreamingSettingsSnapshot: WhisperKitStreamingSettingsSnapshot {
        WhisperKitStreamingSettingsSnapshot(
            isEnabled: experimentalStreamingPreviewEnabled,
            customModelFolderPath: experimentalStreamingModelFolderPath
        )
    }

    var experimentalStreamingSetupStatus: WhisperKitStreamingModelResolution {
        WhisperKitStreamingModelLocator.resolveModel(
            environment: environment,
            settings: experimentalStreamingSettingsSnapshot,
            fileManager: fileManager,
            bundle: bundle
        )
    }

    var experimentalStreamingSummary: String {
        WhisperKitStreamingModelLocator.userFacingSummary(
            environment: environment,
            settings: experimentalStreamingSettingsSnapshot,
            fileManager: fileManager,
            bundle: bundle
        )
    }

    var experimentalStreamingSelectedFolderDisplay: String? {
        guard let experimentalStreamingModelFolderPath else {
            return nil
        }

        return URL(fileURLWithPath: experimentalStreamingModelFolderPath)
            .standardizedFileURL
            .path
    }

    func updateSelectedInputDeviceSelection(_ selection: String) {
        let resolvedSelection = selection == Self.systemDefaultSelectionID ? nil : selection
        selectedInputDeviceID = resolvedSelection
    }

    func setExperimentalStreamingModelFolderURL(_ url: URL?) {
        experimentalStreamingModelFolderPath = url.map { Self.normalizePath($0.path) } ?? nil
    }

    func clearExperimentalStreamingModelFolder() {
        experimentalStreamingModelFolderPath = nil
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

    private func persistExperimentalStreamingModelFolderPath() {
        if let experimentalStreamingModelFolderPath {
            userDefaults.set(
                experimentalStreamingModelFolderPath,
                forKey: DefaultsKey.experimentalStreamingModelFolderPath
            )
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.experimentalStreamingModelFolderPath)
        }
    }

    private static func clampSensitivity(_ value: Double) -> Double {
        min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    private static func normalizePath(_ rawPath: String?) -> String? {
        guard let rawPath = rawPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else {
            return nil
        }

        return NSString(string: rawPath).expandingTildeInPath
    }

    private static func defaultExperimentalStreamingPreviewEnabled(
        userDefaults: UserDefaults,
        environment: [String: String],
        fileManager: FileManager,
        bundle: Bundle,
        customModelFolderPath: String?
    ) -> Bool {
        if let storedValue = userDefaults.object(
            forKey: DefaultsKey.experimentalStreamingPreviewEnabled
        ) as? Bool {
            return storedValue
        }

        let defaultSettings = WhisperKitStreamingSettingsSnapshot(
            isEnabled: true,
            customModelFolderPath: customModelFolderPath
        )

        if case .ready = WhisperKitStreamingModelLocator.resolveModel(
            environment: environment,
            settings: defaultSettings,
            fileManager: fileManager,
            bundle: bundle
        ) {
            return true
        }

        return false
    }

    private static func removeObsoleteTranscriptionDefaults(from userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: DefaultsKey.legacyTranscriptionMode)
        userDefaults.removeObject(forKey: DefaultsKey.legacyProfileKey)
    }
}
