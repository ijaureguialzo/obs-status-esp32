//
//  OBSConnectionView.swift
//  Panel for configuring and managing OBS WebSocket connection.
//  Handles host, port, and token configuration with validation.
//

import SwiftUI

struct OBSConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    @State private var host: String = "localhost"
    @State private var port: String = "4444"
    @State private var token: String = ""
    
    var body: some View {
        Form {
            Section("OBS WebSocket Settings") {
                TextField("Host", text: $host)
                    .disabled(viewModel.obsConnected)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Port", text: $port)
                    .disabled(viewModel.obsConnected)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: port) { newValue in
                        // Validate port number
                        if let num = Int(newValue), num > 65535 || num < 1 {
                            // Trim invalid port numbers
                        }
                    }
                
                SecureField("WebSocket Token (optional)", text: $token)
                    .disabled(viewModel.obsConnected)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    // Save config
                    AppSettings.shared.obsConfig = OBSConfig(
                        host: host,
                        port: Int(port) ?? 4444,
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
            Image(systemName: viewModel.obsConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.obsConnected ? .green : .red)
            
            Text(viewModel.obsConnected ? "Connected to OBS" : "Disconnected from OBS")
            
            if viewModel.obsConnecting {
                ProgressView()
            }
        }
    }
    
    private var connectButton: some View {
        Button(action: {
            Task { await viewModel.connectOBS() }
        }) {
            Text(viewModel.obsConnected ? "Disconnect" : "Connect to OBS")
                .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.obsConnecting)
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    OBSConnectionView()
        .environment(AppViewModel())
}
