//
//  OBSConnectionView.swift
//  Panel for configuring and managing OBS WebSocket connection
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
                
                TextField("Port", text: $port)
                    .disabled(viewModel.obsConnected)
                    .keyboardType(.numberPad)
                
                SecureField("WebSocket Token (optional)", text: $token)
                    .disabled(viewModel.obsConnected)
                
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
                HStack {
                    Image(systemName: viewModel.obsConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.obsConnected ? .green : .red)
                    
                    Text(viewModel.obsConnected ? "Connected to OBS" : "Disconnected from OBS")
                    
                    if viewModel.obsConnecting {
                        ProgressView()
                    }
                }
            }
            
            Section("Actions") {
                Button(action: {
                    Task { await viewModel.connectOBS() }
                }) {
                    Text(viewModel.obsConnected ? "Disconnect" : "Connect to OBS")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.obsConnecting)
                .buttonStyle(.borderedProminent)
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
}

#Preview {
    OBSConnectionView()
        .environment(AppViewModel())
}
