//
//  LEDIndicatorView.swift
//  Large visual indicator showing current OBS recording status.
//  Mirrors the ESP32 LED state with a solid color fill (no glow halo); the
//  content adapts its color to stay legible on top of any background.
//

import SwiftUI

struct LEDIndicatorView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Main LED circle (solid fill, no glow around it)
            Circle()
                .fill(circleFill)
                .frame(width: 250, height: 250)
                .overlay {
                    Circle()
                        .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 4))
                }
                .animation(.easeInOut(duration: 0.5), value: viewModel.obsRecording)

            // Center icon and status text. Both use a content color derived
            // from the circle background luminance so they stay legible on
            // top of any recording LED color.
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 64))
                    .foregroundColor(iconColor)
                    .symbolEffect(.pulse, options: .repeating, value: viewModel.obsRecording)

                Text(statusText)
                    .font(.title2.bold())
                    .foregroundColor(contentColor)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Text(statusDescription)
                    .font(.caption)
                    .foregroundColor(contentColor.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Computed Properties

    private var circleFill: Color {
        if viewModel.obsRecording {
            return viewModel.recordingLEDColor.color
        }
        return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 0.25)
    }

    /// Approximation of the window background the circle floats on, per
    /// appearance. The explicit sRGB constants (rather than dynamic system
    /// colors) keep the luminance evaluation deterministic.
    private var windowBackground: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.118, green: 0.118, blue: 0.118, opacity: 1)
            : Color(.sRGB, red: 0.925, green: 0.925, blue: 0.929, opacity: 1)
    }

    /// Effective circle background: the fill composited over the window.
    private var circleBackground: Color {
        circleFill.composited(over: windowBackground)
    }

    /// White or black, whichever contrasts best with the circle background.
    private var contentColor: Color {
        circleBackground.contrastingContentColor
    }

    private var borderColor: Color {
        viewModel.obsRecording
            ? viewModel.recordingLEDColor.color.opacity(0.9) : Color.gray.opacity(0.4)
    }

    private var iconName: String {
        switch status {
        case .recording:
            return "record.circle.fill"
        case .connectingOBS:
            return "doc.badge.gearshape"
        case .connectingESP:
            return "cpu"
        case .idle:
            return "speaker.slash.fill"
        case .disconnected:
            return "circle.dashed"
        }
    }

    private var iconColor: Color {
        switch status {
        case .recording:
            return contentColor
        case .connectingOBS, .connectingESP:
            return .orange
        case .idle, .disconnected:
            return contentColor.opacity(0.7)
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case .recording:
            return "● RECORDING"
        case .connectingOBS:
            return "Connecting to OBS"
        case .connectingESP:
            return "Connecting to ESP32"
        case .idle:
            return "Recording: OFF"
        case .disconnected:
            return "Not Connected"
        }
    }

    private var statusDescription: LocalizedStringKey {
        switch status {
        case .recording:
            return "OBS is currently recording.\nThe ESP32 LED is ON."
        case .connectingOBS:
            return "Establishing connection to OBS Studio via WebSocket."
        case .connectingESP:
            return "Establishing connection to ESP32 via USB."
        case .idle:
            return "OBS recording is stopped.\nThe ESP32 LED is OFF."
        case .disconnected:
            if !viewModel.obsConnected {
                return "Connect to OBS Studio first."
            }
            return "Connect to your ESP32 device."
        }
    }

    private var status: Status {
        switch (viewModel.obsConnected, viewModel.espConnected) {
        case (true, true):
            return viewModel.obsRecording ? .recording : .idle
        case (true, false) where viewModel.espConnecting:
            return .connectingESP
        case (false, _) where viewModel.obsConnecting:
            return .connectingOBS
        case (true, false), (false, _):
            return .disconnected
        }
    }

    private enum Status {
        case recording, connectingOBS, connectingESP, idle, disconnected
    }

}

#Preview {
    LEDIndicatorView()
        .environment(AppViewModel())
}
