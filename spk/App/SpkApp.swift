import AppKit
import SwiftUI

@main
struct SpkApp: App {
    @StateObject private var audioSettings: AudioSettingsStore
    @StateObject private var appState: WhisperAppState

    init() {
        let launchSpan = PerformanceTrace.begin("app.launch")
        let audioSettings = AudioSettingsStore()
        DebugLog.startSession()
        NSApplication.shared.applicationIconImage = SpkAppIconImage.make()
        _audioSettings = StateObject(wrappedValue: audioSettings)
        _appState = StateObject(wrappedValue: WhisperAppState(audioSettings: audioSettings))
        PerformanceTrace.end(launchSpan)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(audioSettings)
                .frame(width: 468)
        } label: {
            SpkMenuBarIcon(
                isRecording: appState.isRecording,
                isReady: appState.startupSetupPhase.isReady,
                hasIssue: appState.startupNeedsAttention
            )
        }
        .menuBarExtraStyle(.window)
    }
}
