//
//  ObsStatusMenuBar.swift
//  Optional menu bar integration for running as a background app.
//  Activate by setting LSUIElement to YES in Info.plist.
//

import SwiftUI

struct ObsStatusMenuBar: Scene {
    @State private var viewModel = AppViewModel()
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarControls(viewModel: viewModel)
        } label: {
            MenuBarIcon(viewModel: viewModel)
        }
    }
}

private struct MenuBarIcon: View {
    let viewModel: AppViewModel
    
    var body: some View {
        Image(systemName: menuBarIconName)
            .imageScale(.large)
    }
    
    private var menuBarIconName: String {
        if !viewModel.obsConnected {
            return "circle.slash"
        } else if viewModel.obsRecording {
            return "record.circle.fill"
        }
        return "circle"
    }
}

private struct MenuBarControls: View {
    @State private var viewModel: AppViewModel
    
    var body: some View {
        Group {
            Button("Connect to OBS") {
                Task { await viewModel.connectOBS() }
            }
            .disabled(viewModel.obsConnected)
            
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
            .disabled(viewModel.espConnected || viewModel.selectedDevice == nil)
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}