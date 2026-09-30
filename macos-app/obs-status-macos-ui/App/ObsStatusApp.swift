//
//  ObsStatusApp.swift
//  ObsStatus - macOS application to monitor OBS recording status
//  and control an ESP32 LED indicator via USB serial.
//

import SwiftUI

@main
struct ObsStatusApp: App {
    @State private var viewModel = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
        .commands {
            CommandMenu("ObsStatus") {
                Button("Connect to OBS") {
                    Task { await viewModel.connectOBS() }
                }
                .disabled(viewModel.obsConnected || viewModel.obsConnecting)
                
                Button("Disconnect from OBS") {
                    Task { await viewModel.disconnectOBS() }
                }
                .disabled(!viewModel.obsConnected)
                
                Divider()
                
                Button("Scan for ESP32") {
                    Task { await viewModel.scanDevices() }
                }
                
                Button("Connect to ESP32") {
                    Task { await viewModel.connectESP() }
                }
                .disabled(viewModel.espConnected || viewModel.espConnecting || viewModel.selectedDevice == nil)
                
                Button("Disconnect from ESP32") {
                    viewModel.disconnectESP()
                }
                .disabled(!viewModel.espConnected)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}