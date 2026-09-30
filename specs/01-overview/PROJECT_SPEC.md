# Spec 01: Project Overview

## 1. Problem Statement

OBS Studio provides no physical indicator for its recording state. Streamers and content creators need an immediate, glanceable visual cue showing whether OBS is currently recording, without having to look at their screen.

## 2. Solution

A two-part system:
1. **macOS Application**: Connects to OBS via WebSocket (OBS Studio WebSockets API) to monitor recording state, and controls an ESP32 microcontroller via USB serial.
2. **ESP32 Firmware**: Receives commands from the macOS app over USB CDC (Virtual Serial Port) and controls an onboard LED to indicate recording status.

## 3. System Architecture

```
┌─────────────────────┐         ┌──────────────────────┐         ┌─────────────────┐
│  OBS Studio         │         │  macOS Application    │         │  ESP32 Board     │
│  (WebSocket API)    │◄───────►│  (SwiftUI App)       │◄───────►│  (ESP-IDF)       │
│                     │  ws:4455│                      │  USB    │                 │
│ Recording State     │         │  • Connect to OBS    │  CDC    │ LED Control     │
│ (via WebSocket)     │         │  • Connect to ESP32  │◄───────►│  (onboard LED)  │
└─────────────────────┘         └──────────────────────┘         └─────────────────┘
```

## 4. Components

### 4.1 macOS Application (`macos-app/`)
- **Technology**: Swift + SwiftUI (macOS 14+)
- **Features**:
  - OBS Connection UI: Configure host, port, and authentication token
  - WebSocket v5 client to connect to OBS Studio (default port 4455)
  - Request `GetRecordStatus` and subscribe to `RecordStateChanged`
  - ESP32 Connection UI: Scan and select USB serial device
  - Send LED control commands via USB CDC (Virtual Serial Port)
  - Background operation (menu bar or windowed mode)
  - Settings persistence (saved OBS and ESP32 config)

### 4.2 ESP32 Firmware (`esp32-firmware/`)
- **Technology**: ESP-IDF v5.x (C)
- **Target Hardware**: Freenove ESP32-S3-WROOM (or compatible)
- **Features**:
  - USB CDC (Composite Device) for serial communication with macOS app
  - Protocol parser for incoming commands
  - Onboard LED control (PWM or GPIO toggle)
  - Auto-connection: enumerates as USB device, waits for commands
  - LED patterns: solid (recording), off (not recording), blinking (error/disconnected)

### 4.3 Communication Protocol (`protocol/`)
- Text-based protocol over USB CDC serial
- Commands: `RECORD_START`, `RECORD_STOP`, `STATUS`
- Response format: `OK` / `ERROR: <reason>`
- Baud rate: 115200 (configurable)

## 5. Non-Functional Requirements

- **Latency**: LED response within 500ms of OBS state change
- **Reliability**: Auto-reconnect on OBS or ESP32 disconnection
- **User Experience**: Minimal configuration (pre-filled defaults)
- **Resources**: macOS app < 50MB memory, ESP32 firmware < 256KB

## 6. Out of Scope (Future)

- Audio recording monitoring
- Scene change notifications
- iOS/iPadOS companion app
- Multiple ESP32 devices (multi-zone indicators)
- Cloud sync of recording schedules
