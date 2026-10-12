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

    var connectShouldSucceed = true
    /// Result returned by every sendCommand call.
    var nextCommandResult: Result<String, Error> = .success("OK")
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
        AppSettings(fileURL: URL.temporaryDirectory.appendingPathComponent(
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
        let viewModel = AppViewModel(obsService: obs, usbService: usb, settings: Self.makeSettings())

        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true
        await pump()

        usb.emitEvent("EVENT:TOGGLE_PAUSE")
        await pump()
        XCTAssertEqual(obs.togglePauseCount, 0,
                       "Events from an untrusted device must not drive OBS")
    }

    @MainActor
    func testTrustEnablesEvents() async throws {
        let usb = FakeUSBCDCService()
        let obs = FakeOBSWebSocketService()
        let viewModel = AppViewModel(obsService: obs, usbService: usb, settings: Self.makeSettings())

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
}
