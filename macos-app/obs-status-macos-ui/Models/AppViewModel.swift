//
//  AppViewModel.swift
//  Central state manager for the ObsStatus application
//  Manages connection state for both OBS Studio and ESP32 devices.
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
    var lastESPResponse: String?
    
    // MARK: - Services
    
    private let obsService: OBSWebSocketServiceProtocol
    private let usbService: USBCDCServiceProtocol
    private var statusTask: Task<String?, Never>?
    
    init(obsService: OBSWebSocketServiceProtocol? = nil, usbService: USBCDCServiceProtocol? = nil) {
        self.obsService = obsService ?? OBSWebSocketService()
        self.usbService = usbService ?? USBCDCService()
        
        // Listen for OBS state changes
        observeOBSState()
    }
    
    // MARK: - OBS Connection
    
    func connectOBS() async {
        guard !obsConnected else { return }
        
        // Validate configuration
        let config = AppSettings.shared.obsConfig
        guard !config.host.isEmpty, config.port > 0 else {
            obsError = "Please configure OBS host and port"
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
        obsConnected = false
        obsRecording = false
        await obsService.disconnect()
    }
    
    func updateRecordingState(_ state: RecordingState) {
        obsRecording = (state == .recording)
        
        // Send command to ESP32 if connected
        Task {
            await sendLEDCommand(state)
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
            
            // Start periodic status polling
            startStatusPolling()
            
        } catch {
            espError = error.localizedDescription
        }
        
        espConnecting = false
    }
    
    func disconnectESP() {
        espConnected = false
        stopStatusPolling()
        Task {
            await usbService.disconnect()
        }
    }
    
    // MARK: - LED Control
    
    func sendLEDCommand(_ state: RecordingState) async {
        guard espConnected else { return }
        guard let device = selectedDevice else { return }
        
        let command: ObsCommand
        switch state {
        case .recording:
            command = .ledOn
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
        } catch {
            // Mark ESP as disconnected on error
            await MainActor.run {
                espConnected = false
                self.errorMessage = error.localizedDescription
            }
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
        } catch {}
    }
    
    // MARK: - Private
    
    private func observeOBSState() {
        Task {
            for await state in obsService.recordingStateStream {
                await updateRecordingState(state)
            }
        }
    }
    
    private func startStatusPolling() {
        _ = Task<Void, Never> {
            while espConnected {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch {}  // 2 seconds
                await queryESPStatus()
            }
        }
    }
    
    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
    }
}
