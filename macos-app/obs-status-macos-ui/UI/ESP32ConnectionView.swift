//
//  ESP32ConnectionView.swift
//  Panel for finding and connecting to ESP32 device via USB serial.
//  Includes device picker, connection controls, and status display.
//

import SwiftUI

struct ESP32ConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    
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
                    Picker("ESP32 Device", selection: Binding(
                        get: { viewModel.selectedDevice },
                        set: { viewModel.selectedDevice = $0 }
                    )) {
                        Text("No device")
                            .tag(Optional<USBDevice>(nil))
                        ForEach(viewModel.availableDevices) { device in
                            Text(device.name)
                                .tag(device as USBDevice?)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.espConnected || viewModel.espConnecting)
                }

                Button(action: {
                    Task { await viewModel.scanDevices() }
                }) {
                    Label("Scan Devices", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.espConnected || viewModel.espConnecting)
            }
            
            Section("Connection Status") {
                connectionStatusRow
            }

            if let lastSeen = viewModel.espLastSeen {
                Section("Last seen") {
                    Text(lastSeen, style: .relative)
                        .foregroundStyle(.secondary)
                }
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
            Image(systemName: viewModel.espConnecting ? "arrow.triangle.2.circlepath" :
                    viewModel.espConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.espConnecting ? .orange : viewModel.espConnected ? .green : .red)
            
            Text(viewModel.espConnecting ? "Connecting to ESP32" :
                    viewModel.espConnected ? "Connected to ESP32" : "Disconnected from ESP32")
            
            if viewModel.espConnecting {
                ProgressView()
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: {
            if viewModel.espConnected {
                Task { await viewModel.disconnectESP() }
            } else {
                Task { await viewModel.connectESP() }
            }
        }) {
            Text(viewModel.espConnected ? "Disconnect" : "Connect to ESP32")
                .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.espConnecting || (!viewModel.espConnected && viewModel.selectedDevice == nil))
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    ESP32ConnectionView()
        .environment(AppViewModel())
}