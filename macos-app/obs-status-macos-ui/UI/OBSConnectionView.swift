//
//  OBSConnectionView.swift
//  Panel for configuring and managing OBS WebSocket connection.
//  Handles host, port, and token configuration with validation.
//

import SwiftUI

struct OBSConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    @State private var host: String = "localhost"
    @State private var port: String = "4455"
    @State private var token: String = ""
    
    var body: some View {
        Form {
            Section("OBS WebSocket Settings") {
                TextField("Host", text: $host)
                    .disabled(viewModel.obsConnected)
                
                TextField("Port", text: $port)
                    .disabled(viewModel.obsConnected)
                
                SecureField("WebSocket Token (optional)", text: $token)
                    .disabled(viewModel.obsConnected)
                
                HStack {
                    Spacer()
                    Button("Save Settings", action: saveSettings)
                        .buttonStyle(.bordered)
                }
            }
            
            Section("Connection") {
                HStack {
                    connectionStatusRow
                    Spacer()
                    connectButton
                }
                
                if let error = viewModel.obsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section("Preferences") {
                Toggle("Connect automatically on launch", isOn: Binding(
                    get: { AppSettings.shared.autoConnect },
                    set: { AppSettings.shared.autoConnect = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let config = AppSettings.shared.obsConfig
            host = config.host
            port = String(config.port)
            token = config.token
        }
    }
    
    // MARK: - Computed Properties
    
    private var connectionStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.obsConnecting ? "arrow.triangle.2.circlepath" :
                    viewModel.obsConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.obsConnecting ? .orange : viewModel.obsConnected ? .green : .red)
            
            Text(viewModel.obsConnecting ? "Connecting to OBS" :
                    viewModel.obsConnected ? "Connected to OBS" : "Disconnected from OBS")
            
            if viewModel.obsConnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: toggleConnection) {
            Text(viewModel.obsConnected || viewModel.obsConnecting ? "Disconnect" : "Connect")
                .frame(minWidth: 90)
        }
        .disabled((viewModel.obsConnecting && viewModel.obsConnected) || (!viewModel.obsConnected && !viewModel.obsConnecting &&
            (host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
             !(1...65535).contains(Int(port) ?? 0))))
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
    
    // MARK: - Actions
    
    private func saveSettings() {
        AppSettings.shared.obsConfig = OBSConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? 0,
            token: token
        )
    }
    
    private func toggleConnection() {
        if viewModel.obsConnected || viewModel.obsConnecting {
            Task { await viewModel.disconnectOBS() }
        } else {
            saveSettings()
            Task { await viewModel.connectOBS() }
        }
    }
}

#Preview {
    OBSConnectionView()
        .environment(AppViewModel())
}
