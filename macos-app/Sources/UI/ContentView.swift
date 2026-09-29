//
//  ContentView.swift
//  Main application window with OBS and ESP32 connection panels
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
            // Main content: Large LED indicator
            LEDIndicatorView()
                .padding()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecordingStateBadge(state: viewModel.obsRecording ? .recording : .notRecording)
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
