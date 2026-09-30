//
//  ObsStatusMenuBar.swift
//  Menu bar integration sharing the app's AppViewModel instance.
//

import SwiftUI

struct ObsStatusMenuBar: Scene {
    @Environment(AppViewModel.self) private var viewModel

    var body: some Scene {
        MenuBarExtra {
            MenuBarControls()
        } label: {
            MenuBarIcon(viewModel: viewModel)
        }
    }
}

struct MenuBarIcon: View {
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

struct MenuBarControls: View {
    @Environment(AppViewModel.self) private var viewModel
    
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