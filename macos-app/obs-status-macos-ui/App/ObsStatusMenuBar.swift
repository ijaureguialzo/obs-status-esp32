//
//  ObsStatusMenuBar.swift
//  Menu bar integration sharing the app's AppViewModel instance.
//

import SwiftUI

struct ObsStatusMenuBar: Scene {
    // Injected explicitly rather than read from the environment: a *Scene*
    // struct's @Environment property wrappers resolve from the app-level
    // environment, not from the scene's own .environment() modifier (that
    // one only reaches the scene's content views). Reading
    // @Environment(AppViewModel.self) here crashed at launch with
    // "No Observable" the moment the menu bar label was built.
    let viewModel: AppViewModel

    var body: some Scene {
        MenuBarExtra {
            // Passed explicitly (not via the scene environment) so the menu
            // content does not depend on the scene-level .environment() being
            // delivered to its views.
            MenuBarControls(viewModel: viewModel)
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
    let viewModel: AppViewModel

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

            if viewModel.espConnected && !viewModel.espDeviceTrusted {
                Divider()
                Text(String(localized: "Device untrusted"))
                    .foregroundColor(.orange)
                    .font(.caption)
                Button(String(localized: "Trust this device")) {
                    viewModel.trustDevice()
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
