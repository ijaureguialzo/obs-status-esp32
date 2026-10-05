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
    
    var espConnected: Bool = false
    var espConnecting: Bool = false
    var espError: String?
    
    var availableDevices: [USBDevice] = []
    var selectedDevice: USBDevice?
    
    var errorMessage: String?
    var lastESPResponse: String?
    var espLastSeen: Date?
    var recordingLEDColor: LEDColor = .recordingDefault
    var currentSceneName: String?
    
    // MARK: - Services
    
    @ObservationIgnored private let obsService: OBSWebSocketServiceProtocol
    @ObservationIgnored private let usbService: USBCDCServiceProtocol
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    
    init(obsService: OBSWebSocketServiceProtocol? = nil, usbService: USBCDCServiceProtocol? = nil) {
        self.obsService = obsService ?? OBSWebSocketService()
        self.usbService = usbService ?? USBCDCService()
        self.recordingLEDColor = AppSettings.shared.recordingLEDColor
        
        // Listen for OBS state changes
        observeOBSState()
        observeSceneName()
        observeDeviceEvents()
        observeESPEvents()
    }
    
    // MARK: - OBS Connection
    
    func connectOBS() async {
        guard !obsConnected, !obsConnecting else { return }
        
        // Validate configuration
        let config = AppSettings.shared.obsConfig
        guard !config.host.isEmpty, (1...65535).contains(config.port) else {
            obsError = String(localized: "Please configure a valid OBS host and port")
            return
        }
        
        obsConnecting = true
        obsError = nil
        
        do {
            try await obsService.connect(
                host: config.host,
                port: config.port,
                token: config.token
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
           !availableDevices.contains(where: { $0.path == selectedDevice.path }) {
            self.selectedDevice = nil
        }
        if selectedDevice == nil, let lastPath = AppSettings.shared.lastESPDevicePath {
            selectedDevice = availableDevices.first { $0.path == lastPath }
        }
    }

    func prepare() async {
        await scanDevices()
        guard AppSettings.shared.autoConnect else { return }
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
            AppSettings.shared.lastESPDevicePath = device.path
            await sendLEDCommand(obsService.recordingState)
            await sendSceneCommand(obsService.currentSceneName)

            // Start periodic status polling
            startStatusPolling()
            
        } catch {
            espError = error.localizedDescription
            startStatusPolling()
        }
        
        espConnecting = false
    }
    
    func disconnectESP() async {
        espConnected = false
        espConnecting = false
        stopStatusPolling()
        await usbService.disconnect()
    }
    
    // MARK: - LED Control
    
    func sendLEDCommand(_ state: RecordingState) async {
        guard espConnected else { return }
        guard let device = selectedDevice else { return }
        
        let commandLine: String
        switch state {
        case .recording:
            commandLine = ObsCommand.ledOn(color: recordingLEDColor)
        case .notRecording:
            commandLine = ObsCommand.ledOff.lineTerminated
        case .unknown:
            return
        }

        do {
            let response = try await usbService.sendCommand(commandLine, to: device)
            lastESPResponse = response
            espLastSeen = Date()
            errorMessage = nil
            if ObsProtocolUtil.isErrorResponse(response) {
                espError = response
            }
        } catch {
            espConnected = false
            espError = error.localizedDescription
            errorMessage = error.localizedDescription
            await usbService.disconnect()
        }
    }

    func setRecordingLEDColor(_ color: LEDColor) {
        recordingLEDColor = color
        AppSettings.shared.recordingLEDColor = color
        guard obsRecording else { return }
        Task {
            await sendLEDCommand(.recording)
        }
    }
    
    /// Sends the active OBS scene name so boards with a display can show it.
    func sendSceneCommand(_ sceneName: String?) async {
        guard espConnected, let device = selectedDevice else { return }
        let commandLine = ObsCommand.scene(name: sceneName ?? "")

        do {
            let response = try await usbService.sendCommand(commandLine, to: device)
            lastESPResponse = response
            espLastSeen = Date()
            if ObsProtocolUtil.isErrorResponse(response) {
                espError = response
            }
        } catch {
            espConnected = false
            espError = error.localizedDescription
            errorMessage = error.localizedDescription
            await usbService.disconnect()
        }
    }

    func queryESPStatus() async {
        guard espConnected, let device = selectedDevice else { return }
        
        do {
            let response = try await usbService.sendCommand(
                ObsCommand.status.lineTerminated,
                to: device
            )
            lastESPResponse = response
            espLastSeen = Date()
            errorMessage = nil
            if ObsProtocolUtil.isErrorResponse(response) {
                espError = response
            }
        } catch {
            espConnected = false
            espError = error.localizedDescription
            await usbService.disconnect()
        }
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
    /// asks OBS to pause/resume the recording).
    private func observeESPEvents() {
        Task { [weak self] in
            guard let self else { return }
            for await line in usbService.events {
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
                        await sendLEDCommand(obsService.recordingState)
                        await sendSceneCommand(obsService.currentSceneName)
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