//
//  AppViewModel.swift
//  Central state manager for the ObsStatus application
//

import Foundation
import Combine

@Observable
class AppViewModel: ObservableObject {
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
    
    // MARK: - Services
    
    private let obsService: OBSWebSocketServiceProtocol
    private let usbService: USBCDCServiceProtocol
    
    init(obsService: OBSWebSocketServiceProtocol? = nil, usbService: USBCDCServiceProtocol? = nil) {
        self.obsService = obsService ?? OBSWebSocketService()
        self.usbService = usbService ?? USBCDCService()
        
        // Listen for OBS state changes
        observeOBSState()
    }
    
    // MARK: - OBS Connection
    
    func connectOBS() async {
        guard !obsConnected else { return }
        
        obsConnecting = true
        obsError = nil
        
        do {
            let config = AppSettings.shared.obsConfig
            try await obsService.connect(
                host: config.host,
                port: config.port,
                token: config.token
            )
            obsConnected = true
        } catch {
            obsError = error.localizedDescription
        }
        
        obsConnecting = false
    }
    
    func disconnectOBS() async {
        obsConnected = false
        obsRecording = false
        await obsService.disconnect()
    }
    
    func updateRecordingState(_ state: RecordingState) {
        obsRecording = (state == .recording)
        // Send command to ESP32 if connected
        Task {
            if espConnected, let device = selectedDevice {
                let command = (state == .recording) ? ObsCommand.ledOn : ObsCommand.ledOff
                try await usbService.sendCommand(command.lineTerminated, to: device)
            }
        }
    }
    
    // MARK: - ESP32 Connection
    
    func scanDevices() async {
        availableDevices = await usbService.enumerateDevices()
    }
    
    func connectESP() async {
        guard let device = selectedDevice else { return }
        guard !espConnected else { return }
        
        espConnecting = true
        espError = nil
        
        do {
            try await usbService.connect(device)
            espConnected = true
            espError = nil
        } catch {
            espError = error.localizedDescription
        }
        
        espConnecting = false
    }
    
    func disconnectESP() {
        espConnected = false
        Task {
            await usbService.disconnect()
        }
    }
    
    // MARK: - Private
    
    private func observeOBSState() {
        // Monitor OBS WebSocket events for recording state changes
        Task {
            for await state in obsService.recordingStateStream {
                await updateRecordingState(state)
            }
        }
    }
}
