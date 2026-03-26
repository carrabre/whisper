import Foundation

enum StartupChecklistItemState: Equatable, Sendable {
    case complete
    case active
    case pending
    case blocked
}

struct StartupChecklistItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: StartupChecklistItemState
}

enum StartupSetupFailure: Equatable, Sendable {
    case unstableSigning(String)
    case backend(String)
    case microphonePermission(String)
    case accessibilityPermission(String)

    var message: String {
        switch self {
        case .unstableSigning(let message),
             .backend(let message),
             .microphonePermission(let message),
             .accessibilityPermission(let message):
            return message
        }
    }
}

enum StartupSetupPhase: Equatable, Sendable {
    case checkingSigning
    case preparingBackend
    case requestingMicrophone
    case requestingAccessibility
    case ready
    case failed(StartupSetupFailure)

    var isReady: Bool {
        if case .ready = self {
            return true
        }

        return false
    }
}
