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
                    .textFieldStyle(.roundedBorder)
                
                TextField("Port", text: $port)
                    .disabled(viewModel.obsConnected)
                    .textFieldStyle(.roundedBorder)
                
                SecureField("WebSocket Token (optional)", text: $token)
                    .disabled(viewModel.obsConnected)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    AppSettings.shared.obsConfig = OBSConfig(
                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: Int(port) ?? 0,
                        token: token
                    )
                }) {
                    Text("Save Settings")
                }
                .buttonStyle(.bordered)
            }
            
            Section("Connection Status") {
                connectionStatusRow
            }
            
            Section("Actions") {
                connectButton
            }

            Section("Launch") {
                Toggle("Connect automatically on launch", isOn: Binding(
                    get: { AppSettings.shared.autoConnect },
                    set: { AppSettings.shared.autoConnect = $0 }
                ))
            }
            
            if let error = viewModel.obsError {
                Section("Error") {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .onAppear {
            let config = AppSettings.shared.obsConfig
            host = config.host
            port = String(config.port)
            token = config.token
        }
    }
    
    // MARK: - Computed Properties
    
    private var connectionStatusRow: some View {
        HStack {
            Image(systemName: viewModel.obsConnecting ? "arrow.triangle.2.circlepath" :
                    viewModel.obsConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.obsConnecting ? .orange : viewModel.obsConnected ? .green : .red)
            
            Text(viewModel.obsConnecting ? "Connecting to OBS" :
                    viewModel.obsConnected ? "Connected to OBS" : "Disconnected from OBS")
            
            if viewModel.obsConnecting {
                ProgressView()
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: {
            if viewModel.obsConnected || viewModel.obsConnecting {
                Task { await viewModel.disconnectOBS() }
            } else {
                AppSettings.shared.obsConfig = OBSConfig(
                    host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: Int(port) ?? 0,
                    token: token
                )
                Task { await viewModel.connectOBS() }
            }
        }) {
            Text(viewModel.obsConnected || viewModel.obsConnecting ? "Disconnect" : "Connect to OBS")
                .frame(maxWidth: .infinity)
        }
        .disabled((viewModel.obsConnecting && viewModel.obsConnected) || (!viewModel.obsConnected && !viewModel.obsConnecting &&
            (host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
             !(1...65535).contains(Int(port) ?? 0))))
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    OBSConnectionView()
        .environment(AppViewModel())
}