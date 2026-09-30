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
                    Label("No devices found. Connect your ESP32 and click Scan.", systemImage: "usb.super")
                        .foregroundColor(.secondary)
                } else {
                    Picker("ESP32 Device", selection: Binding(
                        get: { viewModel.selectedDevice },
                        set: { viewModel.selectedDevice = $0 }
                    )) {
                        Text("No device")
                            .tag(Optional<USBDevice>(nil))
                        ForEach(viewModel.availableDevices) { device in
                            Text(device.pickerTitle)
                                .tag(device as USBDevice?)
                        }
                    }
                    .disabled(viewModel.espConnected || viewModel.espConnecting)
                }
                
                HStack {
                    Spacer()
                    Button(action: { Task { await viewModel.scanDevices() } }) {
                        Label("Scan Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.espConnected || viewModel.espConnecting)
                }
            }
            
            Section("Connection") {
                HStack {
                    connectionStatusRow
                    Spacer()
                    connectButton
                }
                
                if let lastSeen = viewModel.espLastSeen {
                    LabeledContent("Last seen") {
                        Text(lastSeen, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let error = viewModel.espError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            if let response = viewModel.lastESPResponse {
                Section("Last ESP32 Response") {
                    Text(response)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if viewModel.availableDevices.isEmpty {
                await viewModel.scanDevices()
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var connectionStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.espConnecting ? "arrow.triangle.2.circlepath" :
                    viewModel.espConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.espConnecting ? .orange : viewModel.espConnected ? .green : .red)
            
            Text(viewModel.espConnecting ? "Connecting to ESP32" :
                    viewModel.espConnected ? "Connected to ESP32" : "Disconnected from ESP32")
            
            if viewModel.espConnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: toggleConnection) {
            Text(viewModel.espConnected ? "Disconnect" : "Connect")
                .frame(minWidth: 90)
        }
        .disabled(viewModel.espConnecting || (!viewModel.espConnected && viewModel.selectedDevice == nil))
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
    
    // MARK: - Actions
    
    private func toggleConnection() {
        if viewModel.espConnected {
            Task { await viewModel.disconnectESP() }
        } else {
            Task { await viewModel.connectESP() }
        }
    }
}

#Preview {
    ESP32ConnectionView()
        .environment(AppViewModel())
}
