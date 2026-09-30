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
    }
    
    // MARK: - OBS Connection
    
    func connectOBS() async {
        guard !obsConnected, !obsConnecting else { return }
        
        // Validate configuration
        let config = AppSettings.shared.obsConfig
        guard !config.host.isEmpty, (1...65535).contains(config.port) else {
            obsError = "Please configure a valid OBS host and port"
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
            AppSettings.shared.lastESPDevicePath = device.path
            await sendLEDCommand(obsService.recordingState)
            
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
        
        let command: ObsCommand
        switch state {
        case .recording:
            do {
                let response = try await usbService.sendCommand(
                    ObsCommand.ledOn(color: recordingLEDColor),
                    to: device
                )
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
            return
        case .notRecording:
            command = .ledOff
        case .unknown:
            return
        }

        do {
            let response = try await usbService.sendCommand(
                command.lineTerminated,
                to: device
            )
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

    func setRecordingLEDColor(_ color: LEDColor) {
        recordingLEDColor = color
        AppSettings.shared.recordingLEDColor = color
        guard obsRecording else { return }
        Task {
            await sendLEDCommand(.recording)
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
                        await sendLEDCommand(obsService.recordingState)
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