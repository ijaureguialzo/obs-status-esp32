//
//  AppViewModelTests.swift
//  Unit tests for AppViewModel: device trust gating of unsolicited events,
//  persistence of trust, and the retry/teardown behavior of command delivery.
//

import Foundation
import XCTest

@testable import ObsStatus

// MARK: - Fakes

/// In-memory USBCDCService double. Lets tests drive the service side of the
/// view model: connect/disconnect outcomes, command results and unsolicited
/// event lines.
final class FakeUSBCDCService: USBCDCServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var deviceContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var logContinuations: [UUID: AsyncStream<SerialLogEntry>.Continuation] = [:]

    var connectShouldSucceed = true
    /// Result returned by every sendCommand call.
    var nextCommandResult: Result<String, Error> = .success("OK")
    /// Makes sendCommand wait a moment and then fail with a read timeout,
    /// so tests can drive a disconnect while a command is in flight.
    var slowFail = false
    private(set) var sentCommands: [String] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    var deviceEvents: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { deviceContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.deviceContinuations[id] = nil }
            }
        }
    }

    var events: AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { eventContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.eventContinuations[id] = nil }
            }
        }
    }

    var logEvents: AsyncStream<SerialLogEntry> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { logContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.logContinuations[id] = nil }
            }
        }
    }

    /// Test hook: deliver an unsolicited line to every event subscriber.
    func emitEvent(_ line: String) {
        let subscribers = lock.withLock { Array(eventContinuations.values) }
        for continuation in subscribers {
            continuation.yield(line)
        }
    }

    func emitDeviceEvent() {
        let subscribers = lock.withLock { Array(deviceContinuations.values) }
        for continuation in subscribers {
            continuation.yield()
        }
    }

    /// Test hook: deliver a communication log entry to every subscriber.
    func emitLogEvent(severity: SyslogSeverity, message: String) {
        let subscribers = lock.withLock { Array(logContinuations.values) }
        for continuation in subscribers {
            continuation.yield(SerialLogEntry(severity, message: message))
        }
    }

    func enumerateDevices() async -> [USBDevice] { [] }

    func connect(_ device: USBDevice) async throws {
        lock.withLock { connectCount += 1 }
        guard connectShouldSucceed else { throw USBCDCError.linkNotReady }
    }

    func disconnect() async {
        lock.withLock { disconnectCount += 1 }
    }

    func sendCommand(_ command: String, to device: USBDevice) async throws -> String {
        lock.withLock { sentCommands.append(command) }
        if slowFail {
            try? await Task.sleep(for: .milliseconds(150))
            throw USBCDCError.readFailed(error: 0)
        }
        return try nextCommandResult.get()
    }
}

/// In-memory OBS WebSocket double with controllable state.
@MainActor
final class FakeOBSWebSocketService: OBSWebSocketServiceProtocol {
    private var stateContinuations: [UUID: AsyncStream<RecordingState>.Continuation] = [:]
    private var sceneContinuations: [UUID: AsyncStream<String?>.Continuation] = [:]

    var isConnected = false
    var isReconnecting = false
    var recordingState: RecordingState = .unknown
    var currentSceneName: String?
    private(set) var togglePauseCount = 0
    private(set) var disconnectCount = 0

    var recordingStateStream: AsyncStream<RecordingState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(recordingState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations[id] = nil
                }
            }
        }
    }

    var sceneNameStream: AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            sceneContinuations[id] = continuation
            continuation.yield(currentSceneName)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sceneContinuations[id] = nil
                }
            }
        }
    }

    func setRecordingState(_ state: RecordingState) {
        recordingState = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    func setSceneName(_ name: String?) {
        currentSceneName = name
        for continuation in sceneContinuations.values {
            continuation.yield(name)
        }
    }

    func connect(host: String, port: Int, token: String, secure: Bool) async throws {}

    func disconnect() {
        disconnectCount += 1
        for continuation in stateContinuations.values { continuation.finish() }
        for continuation in sceneContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        sceneContinuations.removeAll()
    }

    func toggleRecordPause() async {
        togglePauseCount += 1
    }
}

// MARK: - Tests

final class AppViewModelTests: XCTestCase {
    /// Devices are identified by serial number when present, so two boards on
    /// the same port differ; clones without the serial fall back to the path.
    private static let device = USBDevice(
        vendorID: 0x303A,
        productID: 0x1001,
        serialNumber: "TEST-SERIAL",
        name: "test-device",
        path: "/dev/cu.debug-console"
    )

    @MainActor
    private static func makeSettings() -> AppSettings {
        AppSettings(
            fileURL: URL.temporaryDirectory.appendingPathComponent(
                "obs-status-test-\(UUID().uuidString).json"))
    }

    /// The observe- loops in the view model are scheduled tasks; give them a
    /// chance to subscribe before emitting.
    private func pump(_ ms: UInt64 = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    @MainActor
    func testEventsIgnoredUntilDeviceTrusted() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())

        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
        await pump()

        usb.emitEvent("EVENT:TOGGLE_PAUSE")
        await pump()
        XCTAssertEqual(
            obs.togglePauseCount, 0,
            "Events from an untrusted device must not drive OBS")
    }

    @MainActor
    func testTrustEnablesEvents() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())

        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
        await pump()

        viewModel.trustDevice()
        XCTAssertTrue(viewModel.espDeviceTrusted)
        XCTAssertNil(viewModel.espWarning)

        usb.emitEvent("EVENT:TOGGLE_PAUSE")
        await pump()
        XCTAssertEqual(obs.togglePauseCount, 1)
    }

    @MainActor
    func testTrustIsPersistedPerDeviceIdentity() async throws {
        let fileURL = URL.temporaryDirectory.appendingPathComponent(
            "obs-status-test-\(UUID().uuidString).json")
        let settings = AppSettings(fileURL: fileURL)
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(obsService: obs, usbService: usb, settings: settings)

        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
        viewModel.trustDevice()

        // A fresh settings instance reading the same file sees the trust.
        let reloaded = AppSettings(fileURL: fileURL)
        XCTAssertTrue(reloaded.isESPDeviceTrusted(Self.device))
        try? FileManager.default.removeItem(at: fileURL)
    }

    @MainActor
    func testCloneWithoutSerialDoesNotInheritTrust() async throws {
        let fileURL = URL.temporaryDirectory.appendingPathComponent(
            "obs-status-test-\(UUID().uuidString).json")
        let settings = AppSettings(fileURL: fileURL)
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(obsService: obs, usbService: usb, settings: settings)

        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
        viewModel.trustDevice()
        XCTAssertTrue(viewModel.espDeviceTrusted)

        // Same port, no serial: a look-alike device.
        let clone = USBDevice(
            vendorID: 0x303A,
            productID: 0x1001,
            serialNumber: nil,
            name: "test-device-clone",
            path: "/dev/cu.debug-console"
        )
        viewModel.selectedDevice = clone
        viewModel.refreshDeviceTrust()

        XCTAssertFalse(viewModel.espDeviceTrusted)
        usb.emitEvent("EVENT:TOGGLE_PAUSE")
        await pump()
        XCTAssertEqual(obs.togglePauseCount, 0)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Command delivery: retries and session lifecycle

    /// Connects the view model to the fake device so `deliver` works.
    @MainActor
    private func connectViewModel(_ viewModel: AppViewModel) {
        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
    }

    /// The OBS streams yield their current state once on subscription, and
    /// the view model pushes every yield to the ESP32; with the fake set to
    /// fail that would end the session before the test starts. Settle the
    /// initial yields with a healthy fake first, then tests switch the fake
    /// to the mode under test and assert relative counts.
    @MainActor
    private func settleViewModel(
        _ viewModel: AppViewModel,
        usb: FakeUSBCDCService
    ) async {
        usb.nextCommandResult = .success("OK")
        connectViewModel(viewModel)
        await pump(150)
    }

    @MainActor
    func testSuccessfulCommandKeepsTheSession() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let baseline = usb.sentCommands.count
        usb.nextCommandResult = .success("STATUS:LED=0,POWER=OFF,ORIENTATION=UP,SCENE=")

        await viewModel.queryESPStatus()

        XCTAssertEqual(usb.sentCommands.count, baseline + 1)
        XCTAssertEqual(usb.sentCommands.last, "STATUS\n")
        XCTAssertTrue(viewModel.espConnected)
        XCTAssertNil(viewModel.espError)
    }

    @MainActor
    func testTransientTimeoutsAreRetriedUntilSuccess() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let baseline = usb.sentCommands.count

        // First attempt times out, the retry succeeds.
        usb.nextCommandResult = .failure(USBCDCError.readFailed(error: 0))
        let inFlight = Task { await viewModel.queryESPStatus() }
        await pump(50)
        usb.nextCommandResult = .success("STATUS:LED=1,POWER=ON,ORIENTATION=UP,SCENE=Live")
        await inFlight.value

        XCTAssertEqual(usb.sentCommands.count, baseline + 2)
        XCTAssertTrue(viewModel.espConnected)
        XCTAssertNil(viewModel.espError)
    }

    @MainActor
    func testExhaustedRetriesEndTheSession() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let baseline = usb.sentCommands.count
        let disconnectBaseline = usb.disconnectCount
        usb.nextCommandResult = .failure(USBCDCError.readFailed(error: 0))

        await viewModel.queryESPStatus()

        XCTAssertEqual(usb.sentCommands.count, baseline + 3, "Three attempts, all failed")
        XCTAssertFalse(viewModel.espConnected)
        XCTAssertNotNil(viewModel.espError)
        XCTAssertEqual(usb.disconnectCount, disconnectBaseline + 1)
    }

    @MainActor
    func testWriteFailuresAreNotRetried() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let baseline = usb.sentCommands.count
        usb.nextCommandResult = .failure(USBCDCError.writeFailed(error: 5))

        await viewModel.queryESPStatus()

        XCTAssertEqual(
            usb.sentCommands.count, baseline + 1, "Non-transient failures must not be retried")
        XCTAssertFalse(viewModel.espConnected)
    }

    @MainActor
    func testWellFormedErrorResponseIsSurfacedNotRetried() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let baseline = usb.sentCommands.count
        usb.nextCommandResult = .success("ERROR: NOT_CONNECTED")

        await viewModel.queryESPStatus()

        XCTAssertEqual(
            usb.sentCommands.count, baseline + 1, "The device answered: the link is healthy")
        XCTAssertTrue(viewModel.espConnected)
        XCTAssertEqual(viewModel.espError, "ERROR: NOT_CONNECTED")
    }

    @MainActor
    func testDisconnectWhileCommandInFlightPreventsTearDown() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(
            obsService: obs, usbService: usb, settings: Self.makeSettings())
        await settleViewModel(viewModel, usb: usb)
        let disconnectBaseline = usb.disconnectCount
        usb.slowFail = true  // fails after 150ms, long after the disconnect below

        let inflight = Task { await viewModel.queryESPStatus() }
        try await Task.sleep(for: .milliseconds(50))
        await viewModel.disconnectESP()
        await inflight.value

        // The stale in-flight failure must not tear the session down a second
        // time (that would double the disconnect calls).
        XCTAssertFalse(viewModel.espConnected)
        XCTAssertEqual(
            usb.disconnectCount, disconnectBaseline + 1, "Teardown must happen exactly once")
    }

    // MARK: - Event log pipe

    private static func makeLogDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "obs-status-test-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func makeViewModelWithLogDirectory(
        usb: FakeUSBCDCService,
        obs: FakeOBSWebSocketService
    ) async throws -> (AppViewModel, URL) {
        let logDirectory = try Self.makeLogDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: logDirectory)
        }
        let viewModel = AppViewModel(
            obsService: obs,
            usbService: usb,
            settings: Self.makeSettings(),
            espLogService: ESP32LogService(directory: logDirectory)
        )
        await pump()  // let observeESPLogEvents() subscribe
        return (viewModel, logDirectory)
    }

    @MainActor
    func testLogEventsAreWrittenToTheFileWhileRecording() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let (viewModel, logDirectory) =
            try await makeViewModelWithLogDirectory(usb: usb, obs: obs)

        // Not recording yet: the pipe must swallow events (no file, no count).
        usb.emitLogEvent(severity: .info, message: "BEFORE_START")
        await pump()
        XCTAssertFalse(viewModel.espLogActive)
        XCTAssertEqual(viewModel.espLogEventCount, 0)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path))?.isEmpty
                == true,
            "No file may exist while the log is not running")

        await viewModel.startESPLog()
        XCTAssertTrue(viewModel.espLogActive)
        let url = try XCTUnwrap(viewModel.espLogFileURL)
        XCTAssertTrue(url.path.hasPrefix(logDirectory.path))
        XCTAssertFalse(url.lastPathComponent.isEmpty)

        usb.emitLogEvent(severity: .warning, message: "NO_RESPONSE_TEST")
        await pump()
        XCTAssertEqual(viewModel.espLogEventCount, 1)
        XCTAssertEqual(viewModel.espLogLastMessage, "NO_RESPONSE_TEST")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            content.contains("NO_RESPONSE_TEST"),
            "The recorded event must reach the session file: \(content)")

        await viewModel.stopESPLog()
        XCTAssertFalse(viewModel.espLogActive)
        // The sealed file stays referenced so the user can reveal it.
        XCTAssertEqual(viewModel.espLogFileURL, url)
    }

    @MainActor
    func testLogToggleStartsAndStops() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let (viewModel, _) = try await makeViewModelWithLogDirectory(usb: usb, obs: obs)

        XCTAssertFalse(viewModel.espLogActive)
        await viewModel.toggleESPLog()
        XCTAssertTrue(viewModel.espLogActive)
        XCTAssertNotNil(viewModel.espLogFileURL)
        await viewModel.toggleESPLog()
        XCTAssertFalse(viewModel.espLogActive)
    }
}
