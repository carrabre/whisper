import AppKit
import Foundation

enum DebugLog {
    private static let queue = DispatchQueue(label: "com.acfinc.spk.debug-log")
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static var cachedLogFileURL: URL?
    private static var fileHandle: FileHandle?

    static func startSession() {
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
        let line = "[\(timestampFormatter.string(from: Date()))] [\(category)] \(message)\n"

        #if DEBUG
        print(line, terminator: "")
        #endif

        guard let data = line.data(using: .utf8) else { return }

        queue.async {
            do {
                try append(data)
            } catch {
                #if DEBUG
                print("[DebugLog] Failed to write log: \(error)")
                #endif
            }
        }
    }

    static func logFileURL() throws -> URL {
        try queue.sync {
            let url = try resolvedLogFileURL(createIfNeeded: true)
            try flushPendingWritesIfNeeded()
            return url
        }
    }

    static func logFilePath() -> String {
        (try? logFileURL().path) ?? "Unavailable"
    }

    static func copyToPasteboard() throws {
        let contents = try queue.sync {
            let url = try resolvedLogFileURL(createIfNeeded: true)
            try flushPendingWritesIfNeeded()
            return try String(contentsOf: url, encoding: .utf8)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents, forType: .string)
    }

    static func revealInFinder() throws {
        let url = try logFileURL()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func append(_ data: Data) throws {
        do {
            let handle = try logFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? fileHandle?.close()
            fileHandle = nil

            let handle = try logFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    private static func logFileHandle() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        let url = try resolvedLogFileURL(createIfNeeded: true)
        let handle = try FileHandle(forWritingTo: url)
        fileHandle = handle
        return handle
    }

    private static func flushPendingWritesIfNeeded() throws {
        try fileHandle?.synchronize()
    }

    private static func resolvedLogFileURL(createIfNeeded: Bool) throws -> URL {
        if let cachedLogFileURL {
            if createIfNeeded, !FileManager.default.fileExists(atPath: cachedLogFileURL.path) {
                FileManager.default.createFile(atPath: cachedLogFileURL.path, contents: Data())
            }
            return cachedLogFileURL
        }

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "spk/Logs")

        if createIfNeeded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let fileName = isRunningTests ? "debug-tests.log" : "debug.log"
        let fileURL = directory.appending(path: fileName)
        if createIfNeeded, !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }

        cachedLogFileURL = fileURL
        return fileURL
    }
}
