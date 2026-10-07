//
//  ContentView.swift
//  Main application window with OBS and ESP32 connection panels.
//  Displays a large visual LED indicator showing the current recording status.
//

import SwiftUI

/// Sidebar destinations for the main split view. Keeping the status screen
/// as an explicit, selectable item lets the user always navigate back to it.
enum SidebarSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case obsConnection = "OBS Connection"
    case esp32Device = "ESP32 Device"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .status: return "Status"
        case .obsConnection: return "OBS Connection"
        case .esp32Device: return "ESP32 Device"
        }
    }

    var icon: String {
        switch self {
        case .status: return "dot.radiowaves.left.and.right"
        case .obsConnection: return "network"
        case .esp32Device: return "cpu"
        }
    }
}

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var selection: SidebarSection? = .status

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text(String(format: String(localized: "OBS Status v%1$@ (%2$@)"),
                            ObsStatusVersion.version,
                            ObsStatusVersion.build))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }
        } detail: {
            detailView
                .navigationTitle(selection?.title ?? SidebarSection.status.title)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                RecordingStateBadge(state: viewModel.obsRecording ? .recording : .notRecording)
                    .padding(.leading, 4)
            }

            if let error = viewModel.errorMessage {
                ToolbarItem(placement: .automatic) {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                }
            }
        }
        .task {
            await viewModel.prepare()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .status {
        case .status:
            LEDIndicatorView()
        case .obsConnection:
            OBSConnectionView()
        case .esp32Device:
            ESP32ConnectionView()
        }
    }
}

// MARK: - Supporting Views

private struct RecordingStateBadge: View {
    let state: RecordingState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state == .recording ? Color.red : Color.gray)
                .frame(width: 8, height: 8)

            Text(state == .recording ? LocalizedStringKey("Recording") : LocalizedStringKey("Idle"))
                .font(.caption)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environment(AppViewModel())
}