import SwiftUI

@main
struct WhisperTypeApp: App {
    @StateObject private var audioSettings: AudioSettingsStore
    @StateObject private var appState: WhisperAppState

    init() {
        let audioSettings = AudioSettingsStore()
        _audioSettings = StateObject(wrappedValue: audioSettings)
        _appState = StateObject(wrappedValue: WhisperAppState(audioSettings: audioSettings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(audioSettings)
                .frame(width: 376)
        } label: {
            WhisperTypeMenuBarIcon(
                isRecording: appState.isRecording,
                isBlinkVisible: appState.recordingIndicatorVisible,
                isTranscribing: appState.isTranscribing
            )
        }
        .menuBarExtraStyle(.window)
    }
}
