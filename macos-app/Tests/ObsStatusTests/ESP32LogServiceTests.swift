//
//  ESP32LogServiceTests.swift
//  Unit tests for the ESP32 communication event log: session file naming
//  (and duplicate protection), the syslog line format, and the
//  start/stop/no-op semantics.
//

import Foundation
import XCTest

@testable import ObsStatus

final class ESP32LogServiceTests: XCTestCase {
    /// A fresh directory under the system temp area, removed after each test.
    private func makeLogDirectory() throws -> (URL, ESP32LogService) {
        let directory =
            URL.temporaryDirectory
            .appendingPathComponent("obs-status-test-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, ESP32LogService(directory: directory))
    }

    private func fileContents(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Session file naming

    func testStartCreatesAFileNamedAfterTheStartTime() async throws {
        let (directory, service) = try makeLogDirectory()
        let url = try await service.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.path.hasPrefix(directory.path))
        XCTAssertEqual(url.pathExtension, "log")
        let name = url.lastPathComponent
        let pattern = #"^esp32-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-\d+)?\.log$"#
        XCTAssertNotNil(
            name.range(of: pattern, options: .regularExpression),
            "File name must encode the start date and time, got \(name)")
    }

    func testTwoStartsInTheSameSecondDoNotCollide() async throws {
        let (_, service) = try makeLogDirectory()
        let first = try await service.start()
        await service.stop()
        // Same second: the collision suffix must make the names distinct.
        let second = try await service.start()
        await service.stop()

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let names = [first.lastPathComponent, second.lastPathComponent]
        XCTAssertEqual(Set(names).count, 2, "Session files must be uniquely named")
    }

    func testStartWhileRecordingThrows() async throws {
        let (_, service) = try makeLogDirectory()
        _ = try await service.start()
        do {
            _ = try await service.start()
            XCTFail("Expected alreadyRecording to be thrown")
        } catch {
            guard case ESP32LogError.alreadyRecording = error else {
                return XCTFail("Expected alreadyRecording, got \(error)")
            }
        }
        await service.stop()
    }

    // MARK: - Syslog line format

    func testLogLinesUseTheSyslogFormat() async throws {
        let (_, service) = try makeLogDirectory()
        let url = try await service.start()
        await service.log(SerialLogEntry(.info, message: "Hello syslog"))

        let lines = try fileContents(url)
        XCTAssertEqual(lines.count, 2)  // the "started" record + this one

        // <PRI>MMM dd hh:mm:ss HOSTNAME TAG[PID]: MESSAGE; days below 10
        // are space-padded in syslog ("Oct  3"), the rest are two digits.
        let pattern =
            #"<\d+>[A-Z][a-z]{2} (?:\d\d| \d) \d{2}:\d{2}:\d{2} \S+ obs-status\[\d+\]: Hello syslog"#
        XCTAssertNotNil(
            lines[1].range(of: pattern, options: .regularExpression),
            "Expected a syslog-formatted record, got: \(lines[1])")
    }

    func testSeveritySelectsTheSyslogPriority() async throws {
        let (_, service) = try makeLogDirectory()
        let url = try await service.start()
        for severity in [SyslogSeverity.debug, .info, .notice, .warning, .error] {
            await service.log(SerialLogEntry(severity, message: "m"))
        }

        let lines = try fileContents(url).dropFirst()  // skip the "started" record
        XCTAssertEqual(lines.count, 5)
        for (line, severity) in zip(
            lines, [SyslogSeverity.debug, .info, .notice, .warning, .error])
        {
            let expectedPRI = 23 * 8 + severity.rawValue  // facility local7
            let prefix = "<\(expectedPRI)>"
            XCTAssertTrue(
                line.hasPrefix(prefix),
                "Severity \(severity) must map to PRI \(expectedPRI), got: \(line)")
        }
    }

    func testLineBreaksInMessagesAreFlattened() async throws {
        let (_, service) = try makeLogDirectory()
        let url = try await service.start()
        await service.log(SerialLogEntry(.debug, message: "broken\nline\rhere"))

        let lines = try fileContents(url)
        XCTAssertEqual(lines.count, 2, "Each record must stay on a single line")
        XCTAssertTrue(lines[1].contains("broken line here"))
    }

    func testFormatLineIsDeterministic() {
        let entry = SerialLogEntry(.warning, message: "Something failed")
        let line = ESP32LogService.formatLine(
            entry, timestamp: "Oct  3 14:32:05", hostName: "test-host", processID: 4242)
        XCTAssertEqual(
            line, "<188>Oct  3 14:32:05 test-host obs-status[4242]: Something failed\n")
    }

    // MARK: - Recording semantics

    func testLogWithoutAnActiveSessionIsANoOp() async throws {
        let (directory, service) = try makeLogDirectory()
        await service.log(SerialLogEntry(.info, message: "before start"))

        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording)
        let currentFileURL = await service.currentFileURL
        XCTAssertNil(currentFileURL)
        let contents =
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.isEmpty, "No file may be created before start()")
    }

    func testStopSealsTheFileAndFurtherLogsAreIgnored() async throws {
        let (_, service) = try makeLogDirectory()
        let url = try await service.start()
        await service.log(SerialLogEntry(.debug, message: "while active"))
        await service.stop()

        let afterStop = try Data(contentsOf: url)
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording)
        // The URL of the sealed session is kept for the UI's "reveal in Finder".
        let currentFileURL = await service.currentFileURL
        XCTAssertEqual(currentFileURL, url)

        await service.log(SerialLogEntry(.debug, message: "after stop"))
        XCTAssertEqual(try Data(contentsOf: url), afterStop, "No writes after stop()")
    }

    func testStopWithoutStartIsANoOp() async throws {
        let (_, service) = try makeLogDirectory()
        await service.stop()  // must not crash
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording)
    }
}

// MARK: - AUTH redaction

final class ESP32LogRedactionTests: XCTestCase {
    func testAuthCommandsAreRedacted() {
        XCTAssertEqual(
            USBCDCService.redactedForLog("AUTH:super-secret\n"), "AUTH:[redacted]"
        )
    }

    func testOtherCommandsPassThroughUnchanged() {
        XCTAssertEqual(USBCDCService.redactedForLog("LED_ON:0,255,0\n"), "LED_ON:0,255,0")
        XCTAssertEqual(USBCDCService.redactedForLog("SCENE:My Scene\n"), "SCENE:My Scene")
        XCTAssertEqual(USBCDCService.redactedForLog("STATUS\n"), "STATUS")
    }
}
