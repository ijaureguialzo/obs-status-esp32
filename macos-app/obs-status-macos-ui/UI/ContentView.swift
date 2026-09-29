//
//  ContentView.swift
//  Main application window with OBS and ESP32 connection panels.
//  Displays a large visual LED indicator showing the current recording status.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    var body: some View {
        NavigationSplitView {
            // Sidebar with connection status
            List {
                NavigationLink("OBS Connection") {
                    OBSConnectionView()
                }
                
                NavigationLink("ESP32 Device") {
                    ESP32ConnectionView()
                }
            }
            .listStyle(.sidebar)
        } detail: {
            // Main content: Large LED indicator showing recording status
            LEDIndicatorView()
                .padding()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecordingStateBadge(state: viewModel.obsRecording ? .recording : .notRecording)
            }
            
            ToolbarItemGroup(placement: .automatic) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Spacer()
                
                Text("ObsStatus v1.0.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await viewModel.scanDevices()
        }
    }
}

// MARK: - Supporting Views

private struct RecordingStateBadge: View {
    let state: RecordingState
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state == .recording ? Color.red : Color.gray)
                .frame(width: 8, height: 8)
            
            Text(state == .recording ? "Recording" : "Idle")
                .font(.caption)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppViewModel())
}
