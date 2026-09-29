//
//  LEDIndicatorView.swift
//  Large visual indicator showing current OBS recording status via ESP32 LED
//

import SwiftUI

struct LEDIndicatorView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var animating: Bool = false
    
    var body: some View {
        ZStack {
            // Background glow effect
            Circle()
                .fill(gradient)
                .blur(radius: 40)
                .opacity(0.4)
                .animation(.easeInOut(duration: 0.3), value: viewModel.obsRecording)
            
            // Main LED circle
            Circle()
                .fill(circleFill)
                .frame(width: 200, height: 200)
                .shadow(color: shadowColor, radius: 20, y: 5)
                .overlay {
                    Circle()
                        .strokeBorder(StrokeStyle(lineWidth: 4))
                        .foregroundColor(borderColor)
                }
            
            // Center icon/text
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 48))
                    .foregroundColor(iconColor)
                
                Text(statusText)
                    .font(.title2.bold())
                    .foregroundColor(.primary)
            }
        }
        .onAppear {
            if viewModel.obsRecording {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
        }
        .onChange(of: viewModel.obsRecording) { newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    animating = true
                }
            } else {
                animating = false
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var gradient: Color {
        viewModel.obsRecording ? Color.green : Color.gray.opacity(0.2)
    }
    
    private var circleFill: Color {
        viewModel.obsRecording ? Color.green : Color.gray.opacity(0.3)
    }
    
    private var shadowColor: Color {
        viewModel.obsRecording ? Color.green : Color.clear
    }
    
    private var borderColor: Color {
        viewModel.obsRecording ? Color.green.opacity(0.8) : Color.gray.opacity(0.5)
    }
    
    private var iconName: String {
        if viewModel.obsRecording {
            return "record.circle.fill"
        } else if viewModel.espConnected {
            return "speaker.slash.fill"
        } else {
            return "circle.dashed"
        }
    }
    
    private var statusText: String {
        if !viewModel.obsConnected {
            return "OBS Not Connected"
        } else if !viewModel.espConnected {
            return "ESP32 Not Connected"
        } else if viewModel.obsRecording {
            return "● RECORDING"
        } else {
            return "Recording: OFF"
        }
    }
}

#Preview {
    LEDIndicatorView()
        .environment(AppViewModel())
}
