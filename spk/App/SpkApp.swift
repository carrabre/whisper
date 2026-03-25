import AppKit
import SwiftUI

@main
struct SpkApp: App {
    @StateObject private var audioSettings: AudioSettingsStore
    @StateObject private var appState: WhisperAppState

    init() {
        DebugLog.startSession()
        NSApplication.shared.applicationIconImage = SpkAppIconImage.make()
        let audioSettings = AudioSettingsStore()
        _audioSettings = StateObject(wrappedValue: audioSettings)
        _appState = StateObject(wrappedValue: WhisperAppState(audioSettings: audioSettings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(audioSettings)
                .frame(width: 468)
        } label: {
            SpkMenuBarIcon(
                isRecording: appState.isRecording
            )
        }
        .menuBarExtraStyle(.window)
    }
}
