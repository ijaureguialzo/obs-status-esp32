//
//  ESP32LogService.swift
//  Records the ESP32 communication link's events (commands sent, lines
//  received, connection lifecycle) in a file using the classic syslog
//  line format (RFC 3164).
//
//  Every start() opens a *new* file in the app's Application Support
//  directory; the file name encodes the session's start date and time
//  down to the second, so two sessions can never collide (a numeric
//  suffix breaks ties when two sessions start in the same second).
//

import Foundation
import os

/// Syslog severity levels (RFC 5424 numeric values).
enum SyslogSeverity: Int, Sendable {
    case debug = 7
    case info = 6
    case notice = 5
    case warning = 4
    case error = 3
}

/// One event on the ESP32 communication link, as reported by the USB
/// service. The message is already human-readable; `ESP32LogService`
/// serializes it into a syslog line.
struct SerialLogEntry: Sendable {
    let severity: SyslogSeverity
    let message: String

    /// `nonisolated` because nonisolated contexts (the serial reader task,
    /// the tests) build entries. The unlabeled `severity` parameter keeps
    /// this distinct from the compiler-synthesized memberwise init, which
    /// swift-format's UseSynthesizedInitializer lint would demand removing
    /// (removing the init would lose the `nonisolated`).
    nonisolated init(_ severity: SyslogSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

enum ESP32LogError: LocalizedError {
    case alreadyRecording
    case cannotCreateFile(path: String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return String(localized: "The event log is already running")
        case .cannotCreateFile(let path):
            return String(localized: "Cannot create the event log file: \(path)")
        }
    }
}

/// Appends ESP32 communication events to a local file in classic syslog
/// format (RFC 3164):
///
///     <PRI>MMM dd hh:mm:ss HOSTNAME TAG[PID]: MESSAGE
///
/// Example:
///     <190>Oct 13 14:32:05 my-mac obs-status[4242]: Opened serial port /dev/cu.debug-console
///
/// `PRI` is `facility * 8 + severity` with facility `local7` (23),
/// keeping the application's messages out of the facility ranges macOS
/// itself uses for kernel and system daemon messages.
actor ESP32LogService {
    // MARK: - Configuration

    /// `local7`: the last application-defined syslog facility.
    private static let facility = 23

    private static let tag = "obs-status"

    /// Subsystem for this actor's own `os` diagnostics (not for the file
    /// records). `nonisolated` so it is readable from the stored property
    /// initializer regardless of the default-actor-isolation build setting.
    nonisolated static let subsystem =
        Bundle.main.bundleIdentifier ?? "com.jaureguialzo.obs-status-macos-ui"

    /// Default directory: `~/Library/Application Support/OBS Status`.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("OBS Status", isDirectory: true)
    }

    /// Injectable for tests; defaults to the app's Application Support directory.
    private let directory: URL
    private let fileManager = FileManager.default
    private let hostName = ProcessInfo.processInfo.hostName
    private let processID = Int32(ProcessInfo.processInfo.processIdentifier)
    private let logger = Logger(subsystem: ESP32LogService.subsystem, category: "ESP32Log")

    /// RFC 3164 timestamps use English month names no matter which locale
    /// the user picked for the UI; pin the formatter's locale.
    private let timestampFormatter: DateFormatter

    // MARK: - Session state

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var eventCount = 0

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d HH:mm:ss"
        self.timestampFormatter = formatter
    }

    // MARK: - Session control

    var isRecording: Bool { fileHandle != nil }

    /// URL of the current (or most recent) session file, for the UI to
    /// display the name and offer "reveal in Finder".
    var currentFileURL: URL? { fileURL }

    /// Opens a new session file and starts recording. Each call creates a
    /// freshly named file, so starting a new session never appends to (or
    /// collides with) a previous one.
    func start() throws -> URL {
        guard fileHandle == nil else { throw ESP32LogError.alreadyRecording }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = nextFileURL(start: Date())

        let handle: FileHandle
        do {
            try Data().write(to: url)  // creates the (empty) file
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw ESP32LogError.cannotCreateFile(path: url.path)
        }

        do {
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw ESP32LogError.cannotCreateFile(path: url.path)
        }
        fileHandle = handle
        fileURL = url
        eventCount = 0
        log(
            SerialLogEntry(
                .info, message: "Event logging started (file: \(url.lastPathComponent))"))
        return url
    }

    /// Seals the current session file. The file stays on disk; the next
    /// start() will create a new one.
    func stop() {
        guard let handle = fileHandle else { return }
        log(SerialLogEntry(.info, message: "Event logging stopped (\(eventCount) events)"))
        try? handle.close()
        fileHandle = nil
    }

    /// Appends one event to the session file. Silently ignored while no
    /// session is active, so callers (the USB service) can emit unconditionally.
    func log(_ entry: SerialLogEntry, at date: Date = Date()) {
        guard let handle = fileHandle else { return }
        let line = Self.formatLine(
            entry, timestamp: timestampString(date), hostName: hostName, processID: processID)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            eventCount += 1
        } catch {
            logger.error(
                "Failed to write to the event log file: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Formatting

    /// One syslog (RFC 3164) line, newline-terminated. Static so tests can
    /// pin the exact format.
    static func formatLine(
        _ entry: SerialLogEntry,
        timestamp: String,
        hostName: String,
        processID: Int32
    ) -> String {
        let pri = Self.facility * 8 + entry.severity.rawValue
        // Syslog messages are single-line; a stray line break would split
        // the record, so flatten any that slip in.
        let message = entry.message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "<\(pri)>\(timestamp) \(hostName) \(Self.tag)[\(processID)]: \(message)\n"
    }

    /// `MMM dd hh:mm:ss` (single-digit days are space-padded, as in syslog).
    private func timestampString(_ date: Date) -> String {
        let parts = timestampFormatter.string(from: date).split(separator: " ")
        guard parts.count == 3, let day = Int(parts[1]) else {
            return timestampFormatter.string(from: date)
        }
        return "\(parts[0]) \(String(format: "%2d", day)) \(parts[2])"
    }

    /// `esp32-2025-10-13_14-32-05.log`, with a `-N` suffix when a file
    /// created within the same second already exists.
    private func nextFileURL(start: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: start)
        var fileName = "esp32-\(stamp).log"
        var index = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            index += 1
            fileName = "esp32-\(stamp)-\(index).log"
        }
        return directory.appendingPathComponent(fileName)
    }
}
