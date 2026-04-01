import Combine
import Foundation

struct ModelLanguageSupport: Sendable, Equatable {
    let summary: String
    let detail: String?

    var settingsDescription: String {
        guard let detail, !detail.isEmpty else {
            return summary
        }

        return "\(summary): \(detail)"
    }

    static let whisperEnglishOnly = ModelLanguageSupport(summary: "English only", detail: nil)
    static let whisperMultilingual = ModelLanguageSupport(summary: "99 languages", detail: nil)
    static let voxtralRealtime = ModelLanguageSupport(
        summary: "13 languages",
        detail: "Arabic, German, English, Spanish, French, Hindi, Italian, Dutch, Portuguese, Chinese, Japanese, Korean, Russian"
    )
}

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let systemDefaultSelectionID = "__system_default__"
    static let sensitivityRange = 0.5...2.5

    private enum DefaultsKey {
        static let legacyTranscriptionMode = "transcription.mode"
        static let legacyProfileKey = "ne" + "motron.latencyProfile"
        static let transcriptionBackendSelection = "transcription.backendSelection"
        static let selectedInputDeviceID = "audio.selectedInputDeviceID"
        static let inputSensitivity = "audio.inputSensitivity"
        static let experimentalStreamingPreviewEnabled = "audio.experimentalStreamingPreviewEnabled"
        static let experimentalStreamingModelFolderPath = "audio.experimentalStreamingModelFolderPath"
        static let voxtralRealtimeModelFolderPath = "audio.voxtralRealtimeModelFolderPath"
        static let playAudioCues = "audio.playAudioCues"
        static let automaticallyCopyTranscripts = "transcript.automaticallyCopy"
        static let allowPasteFallback = "transcript.allowPasteFallback"
        static let diagnosticsEnabled = "diagnostics.enabled"
    }

    @Published var transcriptionBackendSelection: TranscriptionBackendSelection {
        didSet {
            userDefaults.set(
                transcriptionBackendSelection.rawValue,
                forKey: DefaultsKey.transcriptionBackendSelection
            )
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

    @Published var voxtralRealtimeModelFolderPath: String? {
        didSet {
            persistVoxtralRealtimeModelFolderPath()
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
        self.transcriptionBackendSelection = Self.defaultTranscriptionBackendSelection(
            userDefaults: userDefaults,
            environment: environment
        )
        self.selectedInputDeviceID = userDefaults.string(forKey: DefaultsKey.selectedInputDeviceID)
        self.inputSensitivity = Self.clampSensitivity(
            userDefaults.object(forKey: DefaultsKey.inputSensitivity) as? Double ?? 1.0
        )
        let initialExperimentalStreamingModelFolderPath = Self.normalizePath(
            userDefaults.string(forKey: DefaultsKey.experimentalStreamingModelFolderPath)
        )
        self.experimentalStreamingModelFolderPath = initialExperimentalStreamingModelFolderPath
        self.voxtralRealtimeModelFolderPath = Self.normalizePath(
            userDefaults.string(forKey: DefaultsKey.voxtralRealtimeModelFolderPath)
        )
        self.experimentalStreamingPreviewEnabled = Self.defaultExperimentalStreamingPreviewEnabled(
            userDefaults: userDefaults,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle,
            customModelFolderPath: initialExperimentalStreamingModelFolderPath
        )
        self.automaticallyCopyTranscripts = userDefaults.object(forKey: DefaultsKey.automaticallyCopyTranscripts) as? Bool ?? false
        self.allowPasteFallback = userDefaults.object(forKey: DefaultsKey.allowPasteFallback) as? Bool ?? true
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

    var transcriptionDisplayName: String {
        transcriptionBackendSelection.displayName
    }

    var transcriptionModelName: String {
        switch transcriptionBackendSelection {
        case .whisper:
            return WhisperBridge.defaultModelDisplayName(environment: environment)
        case .voxtralRealtime:
            switch voxtralRealtimeSetupStatus {
            case .ready(let resolvedModel):
                return resolvedModel.displayName
            case .invalidCustomPath(let path),
                 .invalidEnvironmentPath(let path):
                return URL(fileURLWithPath: path).lastPathComponent
            case .missingModel, .unsupportedHardware:
                return VoxtralRealtimeModelLocator.defaultModelDirectoryName
            }
        }
    }

    var transcriptionModelSupportedLanguages: String {
        switch transcriptionBackendSelection {
        case .whisper:
            return Self.whisperLanguageSupport(
                forModelNamed: transcriptionModelName
            ).settingsDescription
        case .voxtralRealtime:
            return ModelLanguageSupport.voxtralRealtime.settingsDescription
        }
    }

    var transcriptionSettingsDescription: String {
        transcriptionBackendSelection.settingsDescription
    }

    var transcriptionConfigurationFingerprint: String {
        switch transcriptionBackendSelection {
        case .whisper:
            return [
                transcriptionBackendSelection.rawValue,
                experimentalStreamingPreviewEnabled ? "preview-on" : "preview-off",
                experimentalStreamingModelFolderPath ?? ""
            ].joined(separator: "|")
        case .voxtralRealtime:
            return [
                transcriptionBackendSelection.rawValue,
                voxtralRealtimeModelFolderPath ?? ""
            ].joined(separator: "|")
        }
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

    var experimentalStreamingSupportedLanguages: String {
        let modelName: String
        switch experimentalStreamingSetupStatus {
        case .ready(let resolvedModel):
            modelName = resolvedModel.displayName
        case .invalidEnvironmentPath(let path),
             .invalidCustomPath(let path):
            modelName = URL(fileURLWithPath: path).lastPathComponent
        case .disabled, .missingModel, .unsupportedHardware:
            modelName = "openai_whisper-medium"
        }

        return Self.whisperLanguageSupport(forModelNamed: modelName).settingsDescription
    }

    var experimentalStreamingSelectedFolderDisplay: String? {
        guard let experimentalStreamingModelFolderPath else {
            return nil
        }

        return URL(fileURLWithPath: experimentalStreamingModelFolderPath)
            .standardizedFileURL
            .path
    }

    var voxtralRealtimeSettingsSnapshot: VoxtralRealtimeSettingsSnapshot {
        VoxtralRealtimeSettingsSnapshot(
            customModelFolderPath: voxtralRealtimeModelFolderPath
        )
    }

    var voxtralRealtimeSetupStatus: VoxtralRealtimeModelResolution {
        VoxtralRealtimeModelLocator.resolveModel(
            environment: environment,
            settings: voxtralRealtimeSettingsSnapshot,
            fileManager: fileManager
        )
    }

    var voxtralRealtimeSummary: String {
        VoxtralRealtimeModelLocator.userFacingSummary(
            environment: environment,
            settings: voxtralRealtimeSettingsSnapshot,
            fileManager: fileManager,
            bundle: bundle
        )
    }

    var voxtralRealtimeSupportedLanguages: String {
        ModelLanguageSupport.voxtralRealtime.settingsDescription
    }

    var voxtralRealtimeSelectedFolderDisplay: String? {
        guard let voxtralRealtimeModelFolderPath else {
            return nil
        }

        return URL(fileURLWithPath: voxtralRealtimeModelFolderPath)
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

    func setVoxtralRealtimeModelFolderURL(_ url: URL?) {
        voxtralRealtimeModelFolderPath = url.map { Self.normalizePath($0.path) } ?? nil
    }

    func clearVoxtralRealtimeModelFolder() {
        voxtralRealtimeModelFolderPath = nil
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

    private func persistVoxtralRealtimeModelFolderPath() {
        if let voxtralRealtimeModelFolderPath {
            userDefaults.set(
                voxtralRealtimeModelFolderPath,
                forKey: DefaultsKey.voxtralRealtimeModelFolderPath
            )
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.voxtralRealtimeModelFolderPath)
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

    private static func whisperLanguageSupport(forModelNamed modelName: String) -> ModelLanguageSupport {
        let normalizedName = modelName.lowercased()
        if normalizedName.contains(".en") {
            return .whisperEnglishOnly
        }

        return .whisperMultilingual
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

    private static func defaultTranscriptionBackendSelection(
        userDefaults: UserDefaults,
        environment: [String: String]
    ) -> TranscriptionBackendSelection {
        if let environmentSelection = environment[VoxtralRealtimeModelLocator.backendSelectionEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let resolvedSelection = TranscriptionBackendSelection(rawValue: environmentSelection) {
            return resolvedSelection
        }

        if let storedSelection = userDefaults.string(forKey: DefaultsKey.transcriptionBackendSelection),
           let resolvedSelection = TranscriptionBackendSelection(rawValue: storedSelection) {
            return resolvedSelection
        }

        return .whisper
    }

    private static func removeObsoleteTranscriptionDefaults(from userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: DefaultsKey.legacyTranscriptionMode)
        userDefaults.removeObject(forKey: DefaultsKey.legacyProfileKey)
    }
}
