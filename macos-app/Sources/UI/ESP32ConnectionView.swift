//
//  ESP32ConnectionView.swift
//  Panel for finding and connecting to ESP32 device
//

import SwiftUI

struct ESP32ConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    var body: some View {
        Form {
            Section("Device Selection") {
                if viewModel.availableDevices.isEmpty {
                    Text("No devices found")
                        .foregroundColor(.secondary)
                } else {
                    Picker("ESP32 Device", selection: $viewModel.selectedDevice) {
                        ForEach(viewModel.availableDevices) { device in
                            Text(device.name)
                                .tag(device as USBDevice?)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: {
                        Task { await viewModel.scanDevices() }
                    }) {
                        Text("Scan Devices")
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Section("Connection Status") {
                HStack {
                    Image(systemName: viewModel.espConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.espConnected ? .green : .red)
                    
                    Text(viewModel.espConnected ? "Connected to ESP32" : "Disconnected from ESP32")
                    
                    if viewModel.espConnecting {
                        ProgressView()
                    }
                }
            }
            
            Section("Actions") {
                Button(action: {
                    Task { await viewModel.connectESP() }
                }) {
                    Text(viewModel.espConnected ? "Disconnect" : "Connect to ESP32")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.espConnected || viewModel.selectedDevice == nil || viewModel.espConnecting)
                .buttonStyle(.borderedProminent)
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
}

#Preview {
    ESP32ConnectionView()
        .environment(AppViewModel())
}
