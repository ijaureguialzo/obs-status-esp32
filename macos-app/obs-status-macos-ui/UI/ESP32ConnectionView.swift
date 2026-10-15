//
//  ESP32ConnectionView.swift
//  Panel for finding and connecting to ESP32 device via USB serial.
//  Includes device picker, connection controls, and status display.
//

import AppKit
import SwiftUI

struct ESP32ConnectionView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var deviceSecret: String = ""

    var body: some View {
        Form {
            Section("Device Selection") {
                if viewModel.availableDevices.isEmpty {
                    Label(
                        "No devices found. Connect your ESP32 and click Scan.",
                        systemImage: "usb.super"
                    )
                    .foregroundColor(.secondary)
                } else {
                    Picker(
                        "ESP32 Device",
                        selection: Binding(
                            get: { viewModel.selectedDevice },
                            set: { viewModel.selectedDevice = $0 }
                        )
                    ) {
                        Text("No device")
                            .tag(USBDevice?(nil))
                        ForEach(viewModel.availableDevices) { device in
                            Text(device.pickerTitle)
                                .tag(device as USBDevice?)
                        }
                    }
                    .disabled(viewModel.espConnected || viewModel.espConnecting)
                }

                HStack {
                    Spacer()
                    Button(action: { Task { await viewModel.scanDevices() } }) {
                        Label("Scan Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.espConnected || viewModel.espConnecting)
                }
            }

            Section("Connection") {
                HStack {
                    connectionStatusRow
                    Spacer()
                    connectButton
                }

                if let lastSeen = viewModel.espLastSeen {
                    LabeledContent("Last seen") {
                        Text(lastSeen, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.espError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if viewModel.espConnected, !viewModel.espDeviceTrusted {
                    Label(
                        viewModel.espWarning ?? String(localized: "Device untrusted"),
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundColor(.orange)
                    .font(.caption)
                    if viewModel.espAuthSupported {
                        SecureField(String(localized: "Device secret"), text: $deviceSecret)
                        Button(String(localized: "Authenticate")) {
                            Task {
                                await viewModel.authenticateDevice(secret: deviceSecret)
                                // On success the untrusted branch (and the
                                // field) goes away; clear it so a stale
                                // secret is not offered later. On failure
                                // keep the text for a retry.
                                if viewModel.espDeviceTrusted {
                                    deviceSecret = ""
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(String(localized: "Show secret on device")) {
                            Task { await viewModel.showDeviceSecret() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(
                        viewModel.espAuthSupported
                            ? String(localized: "Trust without authentication")
                            : String(localized: "Trust this device")
                    ) {
                        viewModel.trustDevice()
                    }
                    .buttonStyle(.bordered)
                } else if viewModel.espConnected, viewModel.espDeviceTrusted {
                    Label(
                        String(localized: "Device trusted"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundColor(.green)
                    .font(.caption)
                    if viewModel.espAuthSupported {
                        Button(String(localized: "Show secret on device")) {
                            Task { await viewModel.showDeviceSecret() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(String(localized: "Forget this device")) {
                        viewModel.forgetDevice()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section(String(localized: "Event Log")) {
                HStack {
                    HStack(spacing: 6) {
                        Image(
                            systemName: viewModel.espLogActive
                                ? "record.circle.fill" : "circle.dashed"
                        )
                        .foregroundColor(viewModel.espLogActive ? .red : .secondary)

                        Text(
                            viewModel.espLogActive
                                ? LocalizedStringKey("Logging events")
                                : LocalizedStringKey("Logging stopped")
                        )
                    }

                    Spacer()
                    logToggleButton
                }

                if let url = viewModel.espLogFileURL {
                    LabeledContent(String(localized: "File")) {
                        Text(url.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent(String(localized: "Events")) {
                        Text("\(viewModel.espLogEventCount)")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let lastMessage = viewModel.espLogLastMessage {
                        LabeledContent(String(localized: "Last event")) {
                            Text(lastMessage)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    Button(String(localized: "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                } else if !viewModel.espLogActive {
                    Text(
                        String(
                            localized:
                                "Start logging to record everything that happens on the ESP32 link (commands, responses, and events). Each session is saved as a new file in Application Support."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let error = viewModel.espLogError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section("Recording LED Color") {
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { viewModel.recordingLEDColor.color },
                        set: { viewModel.setRecordingLEDColor(LEDColor(color: $0)) }
                    ),
                    supportsOpacity: false
                )
                Text("Applied to the ESP32 while OBS is recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let response = viewModel.lastESPResponse {
                Section("Last ESP32 Response") {
                    Text(response)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if viewModel.availableDevices.isEmpty {
                await viewModel.scanDevices()
            }
        }
    }

    // MARK: - Computed Properties

    private var connectionStatusRow: some View {
        HStack(spacing: 6) {
            Image(
                systemName: viewModel.espConnecting
                    ? "arrow.triangle.2.circlepath"
                    : viewModel.espConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundColor(
                viewModel.espConnecting ? .orange : viewModel.espConnected ? .green : .red)

            Text(
                viewModel.espConnecting
                    ? LocalizedStringKey("Connecting to ESP32")
                    : viewModel.espConnected
                        ? LocalizedStringKey("Connected to ESP32")
                        : LocalizedStringKey("Disconnected from ESP32"))

            if viewModel.espConnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var connectButton: some View {
        Button(action: toggleConnection) {
            Text(
                viewModel.espConnected
                    ? LocalizedStringKey("Disconnect") : LocalizedStringKey("Connect")
            )
            .frame(minWidth: 90)
        }
        .disabled(
            viewModel.espConnecting || (!viewModel.espConnected && viewModel.selectedDevice == nil)
        )
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    private var logToggleButton: some View {
        Button {
            Task { await viewModel.toggleESPLog() }
        } label: {
            Label(
                viewModel.espLogActive
                    ? LocalizedStringKey("Stop Logging") : LocalizedStringKey("Start Logging"),
                systemImage: viewModel.espLogActive ? "stop.circle.fill" : "play.circle.fill"
            )
            .frame(minWidth: 90)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.espLogActive ? .red : .accentColor)
    }

    // MARK: - Actions

    private func toggleConnection() {
        if viewModel.espConnected {
            Task { await viewModel.disconnectESP() }
        } else {
            Task { await viewModel.connectESP() }
        }
    }
}

#Preview {
    ESP32ConnectionView()
        .environment(AppViewModel())
}
