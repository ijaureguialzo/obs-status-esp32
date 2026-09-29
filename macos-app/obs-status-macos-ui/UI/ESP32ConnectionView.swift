//
//  ESP32ConnectionView.swift
//  Panel for finding and connecting to ESP32 device via USB serial.
//  Includes device picker, connection controls, and status display.
//

import SwiftUI

struct ESP32ConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var localSelectedDevice: USBDevice? = nil
    
    private var selectedDeviceBinding: Binding<USBDevice?> {
        Binding(
            get: { localSelectedDevice },
            set: { localSelectedDevice = $0; viewModel.selectedDevice = $0 }
        )
    }
    
    var body: some View {
        Form {
            Section("Device Selection") {
                if viewModel.availableDevices.isEmpty {
                    HStack {
                        Image(systemName: "usb.super")
                            .foregroundColor(.secondary)
                        Text("No devices found. Connect your ESP32 and click Scan.")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Picker("ESP32 Device", selection: selectedDeviceBinding) {
                        Text("No device")
                            .tag(Optional<USBDevice>(nil))
                        ForEach(viewModel.availableDevices) { device in
                            Text(device.name)
                                .tag(device as USBDevice?)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: {
                        Task { await viewModel.scanDevices() }
                    }) {
                        Label("Scan Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Section("Connection Status") {
                connectionStatusRow
            }
            
            if let response = viewModel.lastESPResponse {
                Section("Last ESP32 Response") {
                    Text(response)
                        .font(.system(.body, design: .monospaced))
                }
            }
            
            Section("Actions") {
                connectButton
            }
            
            if let error = viewModel.espError {
                Section("Error") {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .task {
            if viewModel.availableDevices.isEmpty {
                await viewModel.scanDevices()
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var connectionStatusRow: some View {
        HStack {
            Image(systemName: viewModel.espConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.espConnected ? .green : .red)
            
            Text(viewModel.espConnected ? "Connected to ESP32" : "Disconnected from ESP32")
            
            if viewModel.espConnecting {
                ProgressView()
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: {
            Task { await viewModel.connectESP() }
        }) {
            Text(viewModel.espConnected ? "Disconnect" : "Connect to ESP32")
                .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.espConnected || viewModel.selectedDevice == nil || viewModel.espConnecting)
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    ESP32ConnectionView()
        .environment(AppViewModel())
}
