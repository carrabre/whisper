import AVFoundation
import AppKit
import ApplicationServices
import Foundation

struct PermissionState {
    let isGranted: Bool
    let description: String
    let explanation: String
    let canRequestDirectly: Bool
    let needsSystemSettings: Bool
}

struct PermissionSnapshot {
    let microphone: PermissionState
    let accessibility: PermissionState

    static func current() -> PermissionSnapshot {
        let manager = PermissionsManager()
        return manager.snapshot()
    }
}

final class PermissionsManager {
    private enum SettingsPane {
        case microphone
        case accessibility

        var url: URL? {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphonePermissionState(),
            accessibility: accessibilityPermissionState()
        )
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func promptForAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openMicrophoneSettings() {
        openSettingsPane(.microphone)
    }

    func openAccessibilitySettings() {
        openSettingsPane(.accessibility)
    }

    private func microphonePermissionState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return PermissionState(
                isGranted: true,
                description: "Granted",
                explanation: "Allows spk to record your voice so it can transcribe speech locally with whisper-medium.",
                canRequestDirectly: false,
                needsSystemSettings: false
            )
        case .notDetermined:
            return PermissionState(
                isGranted: false,
                description: "Not requested",
                explanation: "Allows spk to record your voice so it can transcribe speech locally with whisper-medium.",
                canRequestDirectly: true,
                needsSystemSettings: false
            )
        case .denied, .restricted:
            return PermissionState(
                isGranted: false,
                description: "Denied",
                explanation: "Allows spk to record your voice so it can transcribe speech locally with whisper-medium.",
                canRequestDirectly: false,
                needsSystemSettings: true
            )
        @unknown default:
            return PermissionState(
                isGranted: false,
                description: "Unknown",
                explanation: "Allows spk to record your voice so it can transcribe speech locally with whisper-medium.",
                canRequestDirectly: false,
                needsSystemSettings: true
            )
        }
    }

    private func accessibilityPermissionState() -> PermissionState {
        if AXIsProcessTrusted() {
            return PermissionState(
                isGranted: true,
                description: "Granted",
                explanation: "Allows spk to find the focused text field in another app and insert the transcript at your cursor.",
                canRequestDirectly: false,
                needsSystemSettings: false
            )
        } else {
            return PermissionState(
                isGranted: false,
                description: "Required",
                explanation: "Allows spk to find the focused text field in another app and insert the transcript at your cursor.",
                canRequestDirectly: false,
                needsSystemSettings: true
            )
        }
    }

    private func openSettingsPane(_ pane: SettingsPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
