# OBS Status - OBS Recording Status Indicator

## Overview

A two-part system that monitors OBS Studio recording status and provides a physical indicator via an ESP32
microcontroller: an RGB LED on classic ESP32-S3 boards, or a touch LCD on the Waveshare ESP32-C6-Touch-LCD-1.47.

```
┌─────────────────────┐         ┌──────────────────────┐         ┌──────────────────────┐
│  OBS Studio         │         │  macOS Application   │         │  ESP32 Board         │
│  (WebSocket API)    │◄───────►│  (SwiftUI App)       │◄───────►│  (ESP-IDF)           │
│                     │  ws:4455│                      │  USB    │                      │
│ Recording State     │         │  • Connect to OBS    │  CDC    │ LED Control          │
│ + Active Scene      │         │  • Connect to ESP32  │◄───────►│ (onboard LED)        │
│ (via WebSocket)     │         │                      │         │          —or—        │
│                     │         │                      │  EVENT: │ Touch LCD with scene │
│                     │         │                      │◄────────│ name + tap-to-pause  │
└─────────────────────┘         └──────────────────────┘         └──────────────────────┘
```

## Supported Boards

| Board | PlatformIO environment | Indicator | Extras |
|-------|------------------------|-----------|--------|
| ESP32-S3-DevKit N8R8 (default) | `esp32-s3-dev-kit-n8r8` | Onboard WS2812 RGB LED | — |
| Waveshare ESP32-C6-Touch-LCD-1.47 | `esp32-c6-touch-lcd-1_47` | 172x320 touch LCD | Screen background shows the recording color, the active OBS scene name is displayed (accent-aware, word-wrapped, centered), tapping the screen pauses/resumes the recording, and the screen auto-rotates between landscape USB-right and USB-left using the IMU |

Both boards use their native USB Serial JTAG peripheral, so a single USB-C cable is used for flashing, monitoring and communication with the app.

## Implementation Status

| Component       | Status  | Notes                                       |
|-----------------|---------|---------------------------------------------|
| macOS App (UI)  | ✅ Done | Complete SwiftUI with all panels            |
| macOS WebSocket | ✅ Done | OBS WebSocket v5 client using URLSession    |
| macOS USB CDC   | ✅ Done | IOKit-based serial port enumeration/control |
| ESP32 Firmware  | ✅ Done | Full implementation with all modules        |
| Protocol Parser | ✅ Done | Text command parsing and dispatch           |
| LED Controller  | ✅ Done | WS2812 RGB LED via RMT + dedicated blink task |
| LCD + Touch (C6) | ✅ Done | JD9853 panel via esp_lcd, AXS5106L touch, scene display + tap-to-pause |
| USB CDC (ESP32) | ✅ Done | USB Serial JTAG (ESP32-S3/C6 native USB)         |

## Project Structure

```
obs-status-esp32/
├── specs/                          # Project specifications (SpecKit)
│   ├── 01-overview/
│   │   └── PROJECT_SPEC.md         # Overall system design
│   ├── 02-protocol/
│   │   └── PROTOCOL_SPEC.md        # Communication protocol definition
│   ├── 03-macos-app/
│   │   └── APP_SPEC.md             # macOS app requirements
│   ├── 04-esp32-firmware/
│   │   └── FIRMWARE_SPEC.md        # Firmware requirements
│   └── 05-deployment/
│       └── DEPLOYMENT_SPEC.md      # Build & distribution guide
│
├── protocol/                       # Shared protocol definitions
│   └── obs_protocol.h              # C header (ESP32)
│
├── macos-app/                      # macOS SwiftUI application
│   ├── obs-status-macos-ui.xcodeproj/   # Xcode project
│   ├── obs-status-macos-ui/             # Swift source files
│   │   ├── App/
│   │   │   ├── ObsStatusApp.swift        # @main entry point
│   │   │   └── ObsStatusMenuBar.swift    # Menu bar integration
│   │   ├── UI/
│   │   │   ├── ContentView.swift           # Main window layout
│   │   │   ├── OBSConnectionView.swift     # OBS config panel
│   │   │   ├── ESP32ConnectionView.swift   # ESP32 config panel
│   │   │   └── LEDIndicatorView.swift      # Visual recording indicator
│   │   ├── Services/
│   │   │   ├── OBSWebSocketService.swift   # OBS WebSocket v5 client
│   │   │   └── USBCDCService.swift         # USB serial via IOKit
│   │   ├── Models/
│   │   │   ├── AppViewModel.swift          # Central state manager
│   │   │   ├── OBSConfig.swift             # OBS config model
│   │   │   ├── USBDevice.swift             # USB device model
│   │   │   ├── AppSettings.swift           # Persistent settings
│   │   │   └── ObsProtocol.swift           # Protocol definitions
│   │   ├── Extensions/
│   │   │   └── AsyncStream+Extensions.swift
│   │   ├── Info.plist                    # App configuration
│   │   ├── Resources/Info.plist          # Build-time config
│   │   ├── Package.swift                 # Swift Package description
│   │   └── Assets.xcassets/              # App icons and assets
│
├── esp32-firmware/              # ESP-IDF firmware for ESP32
│   ├── platformio.ini           # PlatformIO configuration (one env per board)
│   ├── CMakeLists.txt           # Build configuration
│   ├── boards/                  # Custom board definitions (S3 N8R8, C6 Touch LCD)
│   ├── components/              # Vendored Waveshare JD9853 / AXS5106 drivers
│   ├── include/
│   │   ├── usb_cdc.h            # USB CDC interface
│   │   ├── led_controller.h     # LED control interface
│   │   ├── display_controller.h # LCD interface (display boards)
│   │   ├── touch_controller.h   # Touch input interface (display boards)
│   │   └── protocol_parser.h    # Command parser interface
│   └── src/
│       ├── main.c               # Application entry point
│       ├── usb/
│       │   └── usb_cdc.c        # USB CDC implementation
│       ├── led/
│       │   └── led_controller.c # LED control implementation
│       ├── display/
│       │   └── display_controller.c # LCD background + scene name rendering
│       ├── touch/
│       │   └── touch_controller.c   # Tap detection -> EVENT:TOGGLE_PAUSE
│       └── protocol/
│           └── protocol_parser.c # Command parser implementation
│
└── LICENSE
```

## Getting Started

### Prerequisites

- **macOS 14.0+** (Sonoma)
- **Xcode 15.0+** (for macOS app)
- **OBS Studio** with the [obs-websocket](https://github.com/obsproject/obs-websocket) plugin
- **ESP32 board**: ESP32-S3-DevKit N8R8 (default target) or Waveshare ESP32-C6-Touch-LCD-1.47; other boards can be enabled in `esp32-firmware/platformio.ini`
- **PlatformIO** (for ESP32 firmware)

### Build with Make

From the repository root:

```bash
make            # Build the ESP32 firmware (default board) and macOS app
make firmware   # Build only the ESP32 firmware
make install    # Upload the firmware to the connected ESP32
make macos      # Build only the macOS app
```

Pick the board that is connected with the `BOARD` variable or the shortcuts:

```bash
make install BOARD=esp32-c6-touch-lcd-1_47   # Waveshare ESP32-C6-Touch-LCD-1.47
make install-c6                              # shortcut for the C6 board
make install-s3                              # shortcut for the ESP32-S3 board
```

### 1. macOS Application (Xcode)

**Build with Xcode:**

1. Open `macos-app/obs-status-macos-ui.xcodeproj` in Xcode
2. Select your target scheme (macOS 14.0+)
3. Build and run (`Cmd+R`)

**Alternatively, build via command line:**

```bash
cd macos-app
xcodebuild -scheme obs-status-macos-ui -configuration Debug build
```

**Swift Package (alternative):**

```bash
cd macos-app
swift build
```

### 2. ESP32 Firmware

```bash
cd esp32-firmware

# Build firmware (default environment: esp32-s3-dev-kit-n8r8)
pio run

# Build firmware for the Waveshare ESP32-C6-Touch-LCD-1.47
pio run -e esp32-c6-touch-lcd-1_47

# Upload to ESP32 (default environment)
pio run -t upload

# Upload to the C6 board
pio run -e esp32-c6-touch-lcd-1_47 -t upload

# Monitor serial output
pio device monitor -b 115200
```

### 3. Usage

1. Install and enable the obs-websocket plugin in OBS Studio
2. Launch the ObsStatus macOS application
3. Configure OBS connection (host, port, token)
4. Connect to OBS Studio
5. Select your ESP32 device from the dropdown
6. Connect to ESP32
7. The onboard LED will now respond to OBS recording state! On the
   ESP32-C6-Touch-LCD-1.47 the screen shows the active scene name and fills
   with the recording color while recording; tap the screen to pause or
   resume the recording.

## Communication Protocol

Text-based protocol over USB CDC serial (115200 baud, 8N1 — the baud rate is configured on the macOS side only; the ESP32 USB Serial JTAG ignores it):

| Command                       | Description                                          |
|-------------------------------|------------------------------------------------------|
| `LED_ON`                      | Turn LED on with the legacy green color              |
| `LED_ON:<red>,<green>,<blue>` | Turn LED on with an RGB color (each component 0–255) |
| `LED_OFF`                     | Turn LED off (not recording)                         |
| `BLINK_FAST`                  | Blink fast (error state)                             |
| `BLINK_SLOW`                  | Blink slow (idle/disconnected)                       |
| `STATUS`                      | Query current state                                  |
| `SCENE:<name>`                | Set the active OBS scene name (shown on display boards; ignored otherwise) |

Unsolicited events sent by the ESP32:

| Event                | Description                                             |
|----------------------|---------------------------------------------------------|
| `EVENT:TOGGLE_PAUSE` | User tapped the touch screen; pause/resume the recording |

On display boards, `LED_ON`/`LED_OFF`/blink commands also repaint the screen
background with the corresponding color.

Responses: `OK` or `ERROR: <description>`

Full specification: [specs/02-protocol/PROTOCOL_SPEC.md](specs/02-protocol/PROTOCOL_SPEC.md)

## Specs

Full project specifications organized by component:

- [Project Overview](specs/01-overview/PROJECT_SPEC.md)
- [Communication Protocol](specs/02-protocol/PROTOCOL_SPEC.md)
- [macOS Application](specs/03-macos-app/APP_SPEC.md)
- [ESP32 Firmware](specs/04-esp32-firmware/FIRMWARE_SPEC.md)
- [Deployment & Distribution](specs/05-deployment/DEPLOYMENT_SPEC.md)

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.
