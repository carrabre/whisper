import AppKit
import Foundation
import os
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

    static func log(_ message: @autoclosure () -> String, category: String = "app") {
        guard isCollectionEnabled else { return }
        let rawMessage = message()
        let resolvedMessage = shouldRedactSensitiveMetadata ? sanitize(rawMessage) : rawMessage
        let line = "[\(timestampFormatter.string(from: Date()))] [\(category)] \(resolvedMessage)\n"

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

struct PerformanceSpan: Sendable {
    fileprivate let name: String
    fileprivate let startNanoseconds: UInt64
    fileprivate let signpostIDValue: UInt64
}

enum PerformanceTrace {
    private static let log = OSLog(subsystem: "com.acfinc.spk", category: "performance")

    @discardableResult
    static func begin(
        _ name: String,
        metadata: @autoclosure () -> String = ""
    ) -> PerformanceSpan {
        let signpostID = OSSignpostID(log: log)
        let metadata = metadata()
        os_signpost(
            .begin,
            log: log,
            name: "span",
            signpostID: signpostID,
            "%{public}s %{public}s",
            name,
            metadata
        )
        DebugLog.log(
            performanceMessage(name: name, phase: "begin", elapsedMilliseconds: nil, metadata: metadata),
            category: "performance"
        )
        return PerformanceSpan(
            name: name,
            startNanoseconds: DispatchTime.now().uptimeNanoseconds,
            signpostIDValue: signpostID.rawValue
        )
    }

    static func end(
        _ span: PerformanceSpan,
        metadata: @autoclosure () -> String = ""
    ) {
        let elapsedMilliseconds = milliseconds(since: span.startNanoseconds)
        let metadata = metadata()
        os_signpost(
            .end,
            log: log,
            name: "span",
            signpostID: OSSignpostID(span.signpostIDValue),
            "%{public}s %{public}s elapsedMs=%.1f",
            span.name,
            metadata,
            elapsedMilliseconds
        )
        DebugLog.log(
            performanceMessage(
                name: span.name,
                phase: "end",
                elapsedMilliseconds: elapsedMilliseconds,
                metadata: metadata
            ),
            category: "performance"
        )
    }

    static func event(
        _ name: String,
        metadata: @autoclosure () -> String = ""
    ) {
        let metadata = metadata()
        os_signpost(
            .event,
            log: log,
            name: "event",
            "%{public}s %{public}s",
            name,
            metadata
        )
        DebugLog.log(
            performanceMessage(name: name, phase: "event", elapsedMilliseconds: nil, metadata: metadata),
            category: "performance"
        )
    }

    static func measure<T>(
        _ name: String,
        metadata: @autoclosure () -> String = "",
        _ body: () throws -> T
    ) rethrows -> T {
        let span = begin(name, metadata: metadata())
        do {
            let result = try body()
            end(span)
            return result
        } catch {
            end(span, metadata: "error=\(error.localizedDescription)")
            throw error
        }
    }

    static func measure<T>(
        _ name: String,
        metadata: @autoclosure () -> String = "",
        _ body: () async throws -> T
    ) async rethrows -> T {
        let span = begin(name, metadata: metadata())
        do {
            let result = try await body()
            end(span)
            return result
        } catch {
            end(span, metadata: "error=\(error.localizedDescription)")
            throw error
        }
    }

    private static func milliseconds(since startNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000
    }

    private static func performanceMessage(
        name: String,
        phase: String,
        elapsedMilliseconds: Double?,
        metadata: String
    ) -> String {
        var fields = [
            "name=\(name)",
            "phase=\(phase)"
        ]
        if let elapsedMilliseconds {
            fields.append("elapsedMs=\(String(format: "%.1f", elapsedMilliseconds))")
        }
        if !metadata.isEmpty {
            fields.append(metadata)
        }
        return fields.joined(separator: " ")
    }
}
