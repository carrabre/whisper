import AppKit
import Foundation
import UniformTypeIdentifiers

enum DebugLog {
    private static let queue = DispatchQueue(label: "com.acfinc.spk.debug-log")
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let maxBufferedLines = 400
    private static var collectionEnabled = true
    private static var bufferedLines: [String] = []
    private static var lastExportedFileURL: URL?

    enum DebugLogError: LocalizedError, Equatable {
        case exportCancelled
        case disabled

        var errorDescription: String? {
            switch self {
            case .exportCancelled:
                return "Diagnostics export was cancelled."
            case .disabled:
                return "Diagnostics are disabled."
            }
        }
    }

    static var shouldRedactSensitiveMetadata: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static var isCollectionEnabled: Bool {
        queue.sync {
            collectionEnabled
        }
    }

    static func setCollectionEnabled(_ enabled: Bool) {
        queue.sync {
            collectionEnabled = enabled
            if !enabled {
                bufferedLines.removeAll()
                lastExportedFileURL = nil
            }
        }
    }

    static func startSession() {
        guard isCollectionEnabled else { return }
        log("==================================================", category: "session")
        log("Session started", category: "session")
        log(
            "bundle=\(Bundle.main.bundleIdentifier ?? "unknown") " +
            "name=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "unknown") " +
            "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") " +
            "build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") " +
            "executable=\(Bundle.main.executableURL?.lastPathComponent ?? "unknown")",
            category: "session"
        )
    }

    static func log(_ message: String, category: String = "app") {
        guard isCollectionEnabled else { return }
        let line = "[\(timestampFormatter.string(from: Date()))] [\(category)] \(message)\n"

        #if DEBUG
        print(line, terminator: "")
        #endif

        queue.async {
            append(line)
        }
    }

    static func displayPath(_ url: URL) -> String {
        url.path
    }

    static func displayProcessIdentifier(_ pid: pid_t) -> String {
        String(pid)
    }

    static func displayBundleIdentifier(_ bundleIdentifier: String?) -> String {
        bundleIdentifier ?? "unknown"
    }

    static func displayApplicationName(_ applicationName: String?) -> String {
        applicationName ?? "unknown"
    }

    static func copyToPasteboard() throws {
        guard isCollectionEnabled else {
            throw DebugLogError.disabled
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot(), forType: .string)
    }

    static func exportInteractively() throws -> URL {
        guard isCollectionEnabled else {
            throw DebugLogError.disabled
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = defaultExportFileName

        guard panel.runModal() == .OK, let url = panel.url else {
            throw DebugLogError.exportCancelled
        }

        try snapshot().write(to: url, atomically: true, encoding: .utf8)
        queue.sync {
            lastExportedFileURL = url
        }
        return url
    }

    static func exportStatusDescription() -> String {
        queue.sync {
            if !collectionEnabled {
                return "Diagnostics are disabled."
            }
            return lastExportedFileURL?.path ?? "Stored in memory until you export diagnostics."
        }
    }

    #if DEBUG
    static func resetForTesting() {
        queue.sync {
            collectionEnabled = true
            bufferedLines.removeAll()
            lastExportedFileURL = nil
        }
    }

    static func snapshotForTesting() -> String {
        snapshot()
    }
    #endif

    private static var defaultExportFileName: String {
        let timestamp = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(isRunningTests ? "spk-diagnostics-tests" : "spk-diagnostics")-\(timestamp).log"
    }

    private static func snapshot() -> String {
        queue.sync {
            bufferedLines.joined()
        }
    }

    private static func append(_ line: String) {
        bufferedLines.append(line)
        if bufferedLines.count > maxBufferedLines {
            bufferedLines.removeFirst(bufferedLines.count - maxBufferedLines)
        }
    }

    private static func sanitize(_ message: String) -> String {
        var sanitized = message
        let replacements: [(pattern: String, replacement: String)] = [
            (#"pid=\d+"#, "pid=<redacted>"),
            (#"bundle=[^\s,\)]+"#, "bundle=<redacted>"),
            (#"owner=.*? pid="#, "owner=<redacted> pid="),
            (#"/(?:Users|private|var|tmp|Applications|Volumes|System)[^\s,\)]*"#, "<path>")
        ]

        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }

        return sanitized
    }
}
