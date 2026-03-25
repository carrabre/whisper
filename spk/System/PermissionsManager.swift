import AVFoundation
import AppKit
import ApplicationServices
import Foundation

struct CodeSigningStatus: Equatable {
    let signature: String
    let authority: String?
    let teamIdentifier: String?
    let hasStableIdentity: Bool

    var isAdHoc: Bool {
        signature.lowercased() == "adhoc"
    }

    var statusLabel: String {
        if hasStableIdentity, let teamIdentifier {
            return "Team \(teamIdentifier)"
        }

        if isAdHoc {
            return "Ad hoc signed"
        }

        return authority ?? "No team identifier"
    }

    var explanation: String {
        if hasStableIdentity {
            return "This installed build keeps a stable Accessibility identity across rebuilds."
        }

        return "Reinstall a team-signed build to keep Accessibility stable across rebuilds. After the signing identity changes, macOS will ask for Accessibility and Microphone again."
    }

    var readyWarning: String {
        if hasStableIdentity {
            return "Signed build is ready."
        }

        if isAdHoc {
            return "This copy of spk is ad hoc signed. Reinstall a team-signed build to keep Accessibility stable across rebuilds."
        }

        return "This copy of spk has no team identifier. Reinstall a team-signed build to keep Accessibility stable across rebuilds."
    }

    static func current(
        bundleURL: URL = Bundle.main.bundleURL,
        codesignOutput: ((URL) -> String?)? = nil
    ) -> CodeSigningStatus {
        let resolvedOutput = codesignOutput?(bundleURL) ?? CodeSigningInspector.codesignOutput(for: bundleURL)
        guard let resolvedOutput, !resolvedOutput.isEmpty else {
            return CodeSigningStatus(
                signature: "unknown",
                authority: nil,
                teamIdentifier: nil,
                hasStableIdentity: false
            )
        }

        return fromCodesignOutput(resolvedOutput)
    }

    static func fromCodesignOutput(_ output: String) -> CodeSigningStatus {
        let normalizedOutput = output.replacingOccurrences(of: "\r\n", with: "\n")
        let signature = firstValue(for: "Signature=", in: normalizedOutput) ?? "signed"
        let authority = firstValue(for: "Authority=", in: normalizedOutput)
        let rawTeamIdentifier = firstValue(for: "TeamIdentifier=", in: normalizedOutput)
        let teamIdentifier: String?
        if let rawTeamIdentifier,
           !rawTeamIdentifier.isEmpty,
           rawTeamIdentifier.lowercased() != "not set" {
            teamIdentifier = rawTeamIdentifier
        } else {
            teamIdentifier = nil
        }

        let isAdHoc = signature.lowercased() == "adhoc" || normalizedOutput.contains("flags=0x2(adhoc)")
        return CodeSigningStatus(
            signature: signature,
            authority: authority,
            teamIdentifier: teamIdentifier,
            hasStableIdentity: !isAdHoc && teamIdentifier != nil
        )
    }

    private static func firstValue(for prefix: String, in output: String) -> String? {
        output
            .split(separator: "\n")
            .lazy
            .compactMap { line -> String? in
                let line = String(line)
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first
    }
}

enum ReleaseInstallValidationError: Error, Equatable {
    case adHocSignature
    case missingTeamIdentifier
    case unexpectedTeamIdentifier(expected: String, actual: String)
}

enum ReleaseInstallValidator {
    static func validateCodesignOutput(
        _ output: String,
        expectedTeamIdentifier: String
    ) throws -> CodeSigningStatus {
        let status = CodeSigningStatus.fromCodesignOutput(output)

        if status.isAdHoc || output.contains("flags=0x2(adhoc)") {
            throw ReleaseInstallValidationError.adHocSignature
        }

        guard let teamIdentifier = status.teamIdentifier else {
            throw ReleaseInstallValidationError.missingTeamIdentifier
        }

        guard teamIdentifier == expectedTeamIdentifier else {
            throw ReleaseInstallValidationError.unexpectedTeamIdentifier(
                expected: expectedTeamIdentifier,
                actual: teamIdentifier
            )
        }

        return status
    }
}

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
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        DebugLog.log("Requesting microphone permission. Current status: \(currentStatus.rawValue)", category: "permissions")

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DebugLog.log("Microphone permission request completed. Granted: \(granted)", category: "permissions")
                continuation.resume(returning: granted)
            }
        }
    }

    func promptForAccessibilityPermission() {
        DebugLog.log("Prompting for accessibility permission.", category: "permissions")
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
                explanation: "Allows spk to record your voice so it can transcribe speech locally on this Mac.",
                canRequestDirectly: false,
                needsSystemSettings: false
            )
        case .notDetermined:
            return PermissionState(
                isGranted: false,
                description: "Not requested",
                explanation: "Allows spk to record your voice so it can transcribe speech locally on this Mac.",
                canRequestDirectly: true,
                needsSystemSettings: false
            )
        case .denied, .restricted:
            return PermissionState(
                isGranted: false,
                description: "Denied",
                explanation: "Allows spk to record your voice so it can transcribe speech locally on this Mac.",
                canRequestDirectly: false,
                needsSystemSettings: true
            )
        @unknown default:
            return PermissionState(
                isGranted: false,
                description: "Unknown",
                explanation: "Allows spk to record your voice so it can transcribe speech locally on this Mac.",
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
        DebugLog.log("Opening settings pane: \(url.absoluteString)", category: "permissions")
        NSWorkspace.shared.open(url)
    }
}

private enum CodeSigningInspector {
    static func codesignOutput(for bundleURL: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", bundleURL.path]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            DebugLog.log("Could not inspect the current app signature: \(error)", category: "permissions")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
