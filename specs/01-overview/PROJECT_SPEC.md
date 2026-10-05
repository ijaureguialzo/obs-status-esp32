# Spec 01: Project Overview

## 1. Problem Statement

OBS Studio provides no physical indicator for its recording state. Streamers and content creators need an immediate, glanceable visual cue showing whether OBS is currently recording, without having to look at their screen.

## 2. Solution

A two-part system:
1. **macOS Application**: Connects to OBS via WebSocket (OBS Studio WebSockets API) to monitor recording state and the active scene, and controls an ESP32 microcontroller via USB serial.
2. **ESP32 Firmware**: Receives commands from the macOS app over USB CDC (Virtual Serial Port) and indicates the recording status on an onboard LED or, on the Waveshare ESP32-C6-Touch-LCD-1.47, on its touch LCD.

## 3. System Architecture

```
┌─────────────────────┐         ┌──────────────────────┐         ┌──────────────────────┐
│  OBS Studio         │         │  macOS Application    │         │  ESP32 Board          │
│  (WebSocket API)    │◄───────►│  (SwiftUI App)       │◄───────►│  (ESP-IDF)            │
│                     │  ws:4455│                      │  USB    │                       │
│ Recording State     │         │  • Connect to OBS    │  CDC    │ LED Control           │
│ + Active Scene      │         │  • Connect to ESP32  │◄───────►│ (onboard LED)         │
│ (via WebSocket)     │         │  • Forward scene &   │         │          —or—         │
│                     │         │    recording state   │  EVENT: │ Touch LCD: scene name │
│                     │         │                      │◄─────── │ + color background +  │
│                     │         │                      │ tap     │ tap to pause/resume   │
└─────────────────────┘         └──────────────────────┘         └──────────────────────┘
```

## 4. Components

### 4.1 macOS Application (`macos-app/`)
- **Technology**: Swift + SwiftUI (macOS 14+)
- **Features**:
  - OBS Connection UI: Configure host, port, and authentication token
  - WebSocket v5 client to connect to OBS Studio (default port 4455)
  - Request `GetRecordStatus` and subscribe to `RecordStateChanged`
  - Request `GetCurrentProgramScene` and subscribe to `CurrentProgramSceneChanged`
  - Invoke `ToggleRecordPause` when the ESP32 reports a touch tap
  - ESP32 Connection UI: Scan and select USB serial device
  - Send LED control and scene commands via USB CDC (Virtual Serial Port)
  - Receive unsolicited events (touch tap) from the ESP32
  - Background operation (menu bar or windowed mode)
  - Settings persistence (saved OBS and ESP32 config)

### 4.2 ESP32 Firmware (`esp32-firmware/`)
- **Technology**: ESP-IDF v5.x (C)
- **Target Hardware**:
  - ESP32-S3-DevKit N8R8 (default; onboard WS2812 RGB LED)
  - Waveshare ESP32-C6-Touch-LCD-1.47 (172x320 JD9853 touch LCD, no onboard LED)
- **Features**:
  - USB CDC (USB Serial JTAG) for serial communication with macOS app
  - Protocol parser for incoming commands
  - Onboard LED control (WS2812 via RMT) on LED-equipped boards
  - On display-equipped boards: screen background mirrors the recording LED
    color, the active OBS scene name is shown, and a screen tap emits
    `EVENT:TOGGLE_PAUSE` to pause/resume the recording
  - Auto-connection: enumerates as USB device, waits for commands
  - LED patterns: solid (recording), off (not recording), blinking (error/disconnected)

### 4.3 Communication Protocol (`protocol/`)
- Text-based protocol over USB CDC serial
- Commands: `LED_ON[:r,g,b]`, `LED_OFF`, `BLINK_FAST`, `BLINK_SLOW`, `STATUS`, `SCENE:<name>`
- Events (ESP32 → macOS): `EVENT:TOGGLE_PAUSE`
- Response format: `OK` / `ERROR: <reason>`
- Baud rate: 115200 (configured host-side; USB Serial JTAG ignores it)

## 5. Non-Functional Requirements

- **Latency**: LED response within 500ms of OBS state change
- **Reliability**: Auto-reconnect on OBS or ESP32 disconnection
- **User Experience**: Minimal configuration (pre-filled defaults)
- **Resources**: macOS app < 50MB memory, ESP32 firmware < 256KB

## 6. Out of Scope (Future)

- Audio recording monitoring
- iOS/iPadOS companion app
- Multiple ESP32 devices (multi-zone indicators)
- Cloud sync of recording schedules
