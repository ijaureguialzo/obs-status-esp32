//
//  AppViewModel.swift
//  Central state manager for the ObsStatus application
//  Manages connection state for both OBS Studio and ESP32 devices.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppViewModel {
    // MARK: - State

    var obsConnected: Bool = false
    var obsRecording: Bool = false
    var obsConnecting: Bool = false
    var obsError: String?
    /// Non-fatal advisory shown in the OBS panel (e.g. plaintext token on
    /// an unencrypted remote connection).
    var obsWarning: String?

    var espConnected: Bool = false
    var espConnecting: Bool = false
    var espError: String?
    /// Whether the connected device was explicitly trusted by the user. Only
    /// trusted devices may drive OBS from unsolicited events (touch tap), so
    /// a look-alike USB device cannot pause/resume the recording on its own.
    var espDeviceTrusted: Bool = false
    /// Whether the connected firmware understands the AUTH command (advises
    /// the UI whether to offer secret authentication or only manual trust).
    var espAuthSupported: Bool = false
    /// Advisory for the ESP32 panel (e.g. a connected but untrusted device).
    var espWarning: String?
    /// Bumped on every connect/disconnect so in-flight commands from a
    /// previous session (rapid connect/disconnect taps) can tell the link
    /// is now owned by a newer session and stop retrying/tearing it down.
    @ObservationIgnored private var espSession = 0
    /// Last LED command sent, remembered per ESP32 session. OBS replays the
    /// recording state on every websocket reconnect, which used to duplicate
    /// LED commands; the session key keeps the (re)connect replay from being
    /// deduplicated (the board may have reset and lost its LED state).
    @ObservationIgnored private var lastSentLEDCommand: (line: String, session: Int)?

    var availableDevices: [USBDevice] = []
    var selectedDevice: USBDevice?

    var errorMessage: String?
    var lastESPResponse: String?
    var espLastSeen: Date?
    var recordingLEDColor: LEDColor = .recordingDefault
    var currentSceneName: String?

    /// Whether the ESP32 communication event log is currently being written.
    var espLogActive: Bool = false
    /// File of the current (or most recent) logging session, so the UI can
    /// show the name and offer "reveal in Finder".
    var espLogFileURL: URL?
    /// Number of link events recorded in the current session.
    var espLogEventCount: Int = 0
    /// Message of the most recently recorded link event (live proof that the
    /// log is capturing traffic).
    var espLogLastMessage: String?
    /// File-level failure from start/stop (shown in the event log section).
    var espLogError: String?

    // MARK: - Services

    @ObservationIgnored private let obsService: OBSWebSocketServiceProtocol
    @ObservationIgnored private let usbService: USBCDCServiceProtocol
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private let espLogService: ESP32LogService

    init(
        obsService: OBSWebSocketServiceProtocol? = nil,
        usbService: USBCDCServiceProtocol? = nil,
        settings: AppSettings? = nil,
        espLogService: ESP32LogService? = nil
    ) {
        self.obsService = obsService ?? OBSWebSocketService()
        self.usbService = usbService ?? USBCDCService()
        self.settings = settings ?? .shared
        self.espLogService = espLogService ?? ESP32LogService()
        self.recordingLEDColor = self.settings.recordingLEDColor

        // Listen for OBS state changes
        observeOBSState()
        observeSceneName()
        observeDeviceEvents()
        observeESPEvents()
        observeESPLogEvents()
    }

    // MARK: - OBS Connection

    func connectOBS() async {
        guard !obsConnected, !obsConnecting else { return }

        // Validate configuration
        let config = self.settings.obsConfig
        guard !config.host.isEmpty, (1...65535).contains(config.port) else {
            obsError = String(localized: "Please configure a valid OBS host and port")
            return
        }

        // Warn (without blocking) when an unencrypted link would cross the
        // network: the token and recording state would travel in the clear.
        let host = config.host.lowercased()
        let isLocalHost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        obsWarning =
            (config.secure || isLocalHost)
            ? nil
            : String(
                localized:
                    "This OBS connection is not encrypted: the token and recording state travel in plaintext. Enable wss if your OBS setup supports it."
            )

        obsConnecting = true
        obsError = nil

        do {
            try await obsService.connect(
                host: config.host,
                port: config.port,
                token: config.token,
                secure: config.secure
            )
            obsConnected = true
            obsError = nil
        } catch {
            obsError = error.localizedDescription
        }

        obsConnecting = false
    }

    func disconnectOBS() async {
        obsConnecting = false
        obsConnected = false
        obsRecording = false
        obsWarning = nil
        obsService.disconnect()
    }

    func updateRecordingState(_ state: RecordingState) {
        obsConnected = obsService.isConnected
        obsConnecting = obsService.isReconnecting
        obsRecording = (state == .recording)

        // Send command to ESP32 if connected
        _ = Task {
            await sendLEDCommand(state)
        }
    }

    // MARK: - ESP32 Connection

    func scanDevices() async {
        availableDevices = await usbService.enumerateDevices()
        if let selectedDevice,
            !availableDevices.contains(where: { $0.path == selectedDevice.path })
        {
            self.selectedDevice = nil
        }
        if selectedDevice == nil, let lastPath = self.settings.lastESPDevicePath {
            selectedDevice = availableDevices.first { $0.path == lastPath }
        }
    }

    func prepare() async {
        await scanDevices()
        guard self.settings.autoConnect else { return }
        await connectOBS()
        if selectedDevice != nil {
            await connectESP()
        }
    }

    func connectESP() async {
        guard let device = selectedDevice else { return }
        guard !espConnected, !espConnecting else { return }

        espConnecting = true
        espError = nil

        do {
            try await usbService.connect(device)
            espConnected = true
            espError = nil
            errorMessage = nil
            espSession &+= 1
            self.settings.lastESPDevicePath = device.path
            await sendLEDCommand(obsService.recordingState)
            await sendSceneCommand(obsService.currentSceneName)
            refreshDeviceTrust()
            await authenticateOnConnect()

            // Start periodic status polling
            startStatusPolling()

        } catch {
            espError = error.localizedDescription
            refreshDeviceTrust()
            startStatusPolling()
        }

        espConnecting = false
    }

    func disconnectESP() async {
        // Idempotent: a stray (double) tap must not bump the session, stop
        // the status polling, or race a link that is already gone.
        guard espConnected else { return }
        espConnected = false
        espConnecting = false
        espDeviceTrusted = false
        espAuthSupported = false
        espWarning = nil
        espSession &+= 1
        stopStatusPolling()
        await usbService.disconnect()
    }

    /// Re-derives the trust state for the connected device and shows an
    /// advisory while it is not trusted (its events are ignored). Internal
    /// (not private) so tests can drive it after a device swap.
    func refreshDeviceTrust() {
        espDeviceTrusted = selectedDevice.map { settings.isESPDeviceTrusted($0) } ?? false
        if espConnected && !espDeviceTrusted {
            espWarning = String(localized: "Device untrusted: screen taps won't control OBS")
        } else {
            espWarning = nil
        }
    }

    /// Grants trust to the connected device (persisted by serial number or
    /// path) so its unsolicited events may drive OBS again. This is the
    /// manual fallback for firmware without AUTH support.
    func trustDevice() {
        guard espConnected, let device = selectedDevice else { return }
        settings.trustESPDevice(device)
        espDeviceTrusted = true
        espWarning = nil
    }

    /// Revokes trust for the connected device (persisted) and deletes its
    /// stored secret, so its unsolicited events are ignored again and a
    /// later reconnection is not re-authenticated silently. The inverse of
    /// `trustDevice()`.
    func forgetDevice() {
        guard espConnected, let device = selectedDevice else { return }
        settings.forgetESPDevice(device)
        settings.removeDeviceSecret(for: device.trustID)
        refreshDeviceTrust()
    }

    /// Authenticates with the device secret entered by the user (shown by the
    /// board on first pairing). A successful AUTH both grants and persists
    /// trust; the secret is kept in the Keychain like the OBS token.
    func authenticateDevice(secret: String) async {
        guard espConnected, let device = selectedDevice else { return }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            espWarning = String(localized: "Enter the device secret first")
            return
        }
        do {
            let response = try await usbService.sendCommand(
                ObsCommand.auth(secret: trimmed), to: device)
            if response == ObsResponse.ok {
                settings.setDeviceSecret(trimmed, for: device.trustID)
                espError = nil
            } else if response == ObsResponse.errorAuth {
                espError = String(localized: "The device rejected the secret")
            } else if ObsResponse.isErrorResponse(response) {
                espError = String(localized: "This device does not support authentication")
            }
        } catch {
            espError = error.localizedDescription
        }
        refreshDeviceTrust()
    }

    /// Asks the connected board to briefly show its authentication secret on
    /// the screen (display boards; accepted and ignored elsewhere). The boot
    /// screen that shows the secret on first pairing is replaced as soon as
    /// the app pushes a scene, so this is the way to read it again later.
    func showDeviceSecret() async {
        guard espConnected, let device = selectedDevice else { return }
        await deliver(ObsCommand.showSecret.lineTerminated, to: device)
    }

    /// After (re)connecting, replay a stored secret if one exists so the user
    /// is not asked to re-enter it. Legacy firmware answers
    /// `ERROR: UNKNOWN_COMMAND`; the device then stays untrusted and the
    /// manual trust prompt from the view model applies.
    private func authenticateOnConnect() async {
        guard espConnected, let device = selectedDevice, !espDeviceTrusted,
            let stored = settings.deviceSecret(for: device.trustID)
        else { return }
        do {
            let response = try await usbService.sendCommand(
                ObsCommand.auth(secret: stored), to: device)
            if response == ObsResponse.ok {
                settings.trustESPDevice(device)
            } else if response == ObsResponse.errorAuth {
                espWarning = String(localized: "The device rejected the stored secret")
            }
            // Legacy firmware (ERROR: UNKNOWN_COMMAND) keeps the generic
            // "untrusted" advisory: the manual trust prompt still applies.
        } catch {
            // Transient: the manual trust prompt remains available.
        }
        refreshDeviceTrust()
    }

    // MARK: - ESP32 Event Log

    /// Toggles the communication event log. Each start opens a freshly
    /// named file (named after the start date and time), so no two sessions
    /// can collide; the stop just seals the current file.
    func toggleESPLog() async {
        if espLogActive {
            await stopESPLog()
        } else {
            await startESPLog()
        }
    }

    func startESPLog() async {
        guard !espLogActive else { return }
        espLogError = nil
        do {
            let url = try await espLogService.start()
            espLogActive = true
            espLogFileURL = url
            espLogEventCount = 0
            espLogLastMessage = nil
        } catch {
            espLogError = error.localizedDescription
        }
    }

    func stopESPLog() async {
        guard espLogActive else { return }
        await espLogService.stop()
        espLogActive = false
        // The file URL and the event count are kept so the user can still
        // reveal the just-finished session in Finder.
    }

    // MARK: - LED Control

    /// Maximum attempts for a single command before the link is declared
    /// dead. Transient read timeouts are retried; write failures are not.
    private static let espCommandMaxAttempts = 3

    func sendLEDCommand(_ state: RecordingState) async {
        guard espConnected, let device = selectedDevice else { return }

        let commandLine: String
        switch state {
        case .recording:
            commandLine = ObsCommand.ledOn(color: recordingLEDColor)
        case .notRecording:
            commandLine = ObsCommand.ledOff.lineTerminated
        case .unknown:
            // OBS is unreachable (or its state is unknown): show the
            // idle/disconnected pattern instead of keeping the last
            // recording color forever.
            commandLine = ObsCommand.blinkSlow.lineTerminated
        }

        // A replay of the same state (OBS re-emits it on every websocket
        // reconnect) does not change the board: skip it. The color is part
        // of the line, so a color change still goes through.
        if lastSentLEDCommand?.line == commandLine, lastSentLEDCommand?.session == espSession {
            return
        }
        lastSentLEDCommand = (commandLine, espSession)
        await deliver(commandLine, to: device)
    }

    func setRecordingLEDColor(_ color: LEDColor) {
        recordingLEDColor = color
        self.settings.recordingLEDColor = color
        guard obsRecording else { return }
        Task {
            await sendLEDCommand(.recording)
        }
    }

    /// Sends the active OBS scene name so boards with a display can show it.
    func sendSceneCommand(_ sceneName: String?) async {
        guard espConnected, let device = selectedDevice else { return }
        let commandLine = ObsCommand.scene(name: sceneName ?? "")
        await deliver(commandLine, to: device)
    }

    func queryESPStatus() async {
        guard espConnected, let device = selectedDevice else { return }
        await deliver(ObsCommand.status.lineTerminated, to: device)
    }

    /// Sends a command to the ESP32, retrying transient read timeouts (slow
    /// device, USB hiccup) before tearing the connection down.
    ///
    /// A well-formed `ERROR:` response means the device answered, so the
    /// link is healthy: it is surfaced, not retried. A write failure or
    /// exhausted retries disconnects the device; the status polling loop
    /// then tries to reconnect with backoff.
    private func deliver(_ commandLine: String, to device: USBDevice) async {
        guard espConnected else { return }
        let session = espSession

        var lastError: Error?
        var succeeded = false
        for attempt in 1...Self.espCommandMaxAttempts {
            do {
                let response = try await usbService.sendCommand(commandLine, to: device)
                lastESPResponse = response
                espLastSeen = Date()
                errorMessage = nil
                if response.hasPrefix(ObsResponse.statusPrefix),
                    response.contains(ObsResponse.statusAuthSupported)
                {
                    espAuthSupported = true
                }
                if ObsResponse.isErrorResponse(response) {
                    espError = response
                } else {
                    // The device answered: clear any stale error left over
                    // from a previous failed attempt.
                    espError = nil
                }
                succeeded = true
                break
            } catch {
                lastError = error
                guard isTransientReadFailure(error), attempt < Self.espCommandMaxAttempts else {
                    break
                }
                espError = error.localizedDescription
                errorMessage = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(500))
                guard espConnected, espSession == session else { return }
            }
        }

        guard !succeeded else { return }
        // A newer session now owns the link (rapid re-connect): don't tear
        // it down just because the previous one's command failed.
        guard espSession == session else { return }

        espConnected = false

        // `notConnected` is the service saying "there is no link": a
        // concurrent disconnect (a UI tap, a sibling command's teardown)
        // already closed the port, or the device went away. There is
        // nothing left to tear down and the device is not at fault, so just
        // sync the state and let the status-polling loop reconnect. Treating
        // it as a link death (error text + disconnect() call) turned benign
        // races into visible connection drops.
        if let usbError = lastError as? USBCDCError, case .notConnected = usbError {
            return
        }

        let message =
            lastError?.localizedDescription
            ?? String(localized: "Lost connection to the ESP32")
        espError = message
        errorMessage = message
        await usbService.disconnect()
    }

    /// A zero-code read failure is the router's response timeout: the device
    /// did not answer, which can be transient. Anything else (write errors,
    /// explicit disconnection) is not retryable.
    private func isTransientReadFailure(_ error: Error) -> Bool {
        guard let usbError = error as? USBCDCError else { return false }
        if case .readFailed(let code) = usbError {
            return code == 0
        }
        return false
    }

    // MARK: - Private

    private func observeOBSState() {
        Task { [weak self] in
            guard let self else { return }
            for await state in obsService.recordingStateStream {
                updateRecordingState(state)
            }
            obsConnected = obsService.isConnected
            obsConnecting = obsService.isReconnecting
        }
    }

    /// Push the active OBS scene name to the ESP32 (boards with a display
    /// show it on screen; other boards acknowledge and ignore it).
    private func observeSceneName() {
        Task { [weak self] in
            guard let self else { return }
            for await name in obsService.sceneNameStream {
                currentSceneName = name
                await sendSceneCommand(name)
            }
        }
    }

    /// React to unsolicited ESP32 events (e.g. a tap on the touch screen
    /// asks OBS to pause/resume the recording). Events from a device the user
    /// has not trusted are dropped: a look-alike USB device must not be able
    /// to toggle the OBS recording on its own.
    private func observeESPEvents() {
        Task { [weak self] in
            guard let self else { return }
            for await line in usbService.events {
                guard espDeviceTrusted else { continue }
                guard let event = ObsEvent.parse(line) else { continue }
                switch event {
                case .togglePause:
                    await obsService.toggleRecordPause()
                }
            }
        }
    }

    /// Re-scan the device list whenever a serial device is plugged in or removed.
    private func observeDeviceEvents() {
        Task { [weak self] in
            guard let self else { return }
            for await _ in usbService.deviceEvents {
                await scanDevices()
            }
        }
    }

    /// Forwards every communication event reported by the USB service to the
    /// event log while the user is recording. The subscription itself is
    /// constant and cheap (the broadcaster drops entries when the log is off);
    /// only `espLogActive` gates the actual file write.
    private func observeESPLogEvents() {
        Task { [weak self] in
            guard let self else { return }
            for await entry in usbService.logEvents {
                guard espLogActive else { continue }
                await espLogService.log(entry)
                espLogEventCount += 1
                espLogLastMessage = entry.message
            }
        }
    }

    private func startStatusPolling() {
        stopStatusPolling()
        statusTask = Task {
            var retryDelay = 2
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
                guard let device = selectedDevice else { continue }
                if !espConnected {
                    espConnecting = true
                    do {
                        try await usbService.connect(device)
                        guard !Task.isCancelled else {
                            await usbService.disconnect()
                            return
                        }
                        espConnected = true
                        espConnecting = false
                        espError = nil
                        errorMessage = nil
                        espSession &+= 1
                        await sendLEDCommand(obsService.recordingState)
                        await sendSceneCommand(obsService.currentSceneName)
                        refreshDeviceTrust()
                        await authenticateOnConnect()
                    } catch {
                        espConnecting = false
                        espError = error.localizedDescription
                        retryDelay = min(retryDelay * 2, 30)
                        continue
                    }
                }
                await queryESPStatus()
                retryDelay = espConnected ? 2 : min(retryDelay * 2, 30)
            }
        }
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
    }
}
