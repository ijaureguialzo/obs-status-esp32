# ObsStatus - OBS Recording Status Indicator

```
 _________________________________________
/ Wings of OS/400: The airline has bought \
| ancient DC-3s, arguably the best and    |
| safest planes that ever flew, and       |
| painted "747" on their tails to make    |
| them look as if they are fast. The      |
| flight attendants, of course, attend to |
| your every need, though the drinks cost |
| $15 a pop. Stupid questions cost $230   |
| per hour, unless you have SupportLine,  |
| which requires a first class ticket and |
| membership in the frequent flyer club.  |
| Then they cost $500, but your           |
| accounting department can call it       |
\ overhead.                               /
 -----------------------------------------
         \   ^__^
          \  (oo)\_______
             (__)\       )\/\
                 ||----w |
                 ||     ||
```

## Overview

A two-part system that monitors OBS Studio recording status and provides a physical LED indicator via an ESP32 microcontroller.

```
┌─────────────────────┐         ┌──────────────────────┐         ┌─────────────────┐
│  OBS Studio         │         │  macOS Application    │         │  ESP32 Board     │
│  (WebSocket API)    │◄───────►│  (SwiftUI App)       │◄───────►│  (ESP-IDF)       │
│                     │  ws:4455│                      │  USB    │                 │
│ Recording State     │         │  • Connect to OBS    │  CDC    │ LED Control     │
│ (via WebSocket)     │         │  • Connect to ESP32  │◄───────►│  (onboard LED)  │
└─────────────────────┘         └──────────────────────┘         └─────────────────┘
```

## Implementation Status

| Component       | Status  | Notes                                     |
|-----------------|---------|---------------------------------------------|
| macOS App (UI)  | ✅ Done | Complete SwiftUI with all panels            |
| macOS WebSocket | ✅ Done | OBS WebSocket v5 client using URLSession     |
| macOS USB CDC   | ✅ Done | IOKit-based serial port enumeration/control |
| ESP32 Firmware  | ✅ Done | Full implementation with all modules        |
| Protocol Parser | ✅ Done | Text command parsing and dispatch           |
| LED Controller  | ✅ Done | GPIO + FreeRTOS timer for blink patterns    |
| USB CDC (ESP32) | ✅ Done | Full USB CDC-ACM device implementation      |

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
│   ├── platformio.ini           # PlatformIO configuration
│   ├── CMakeLists.txt           # Build configuration
│   ├── include/
│   │   ├── usb_cdc.h            # USB CDC interface
│   │   ├── led_controller.h     # LED control interface
│   │   └── protocol_parser.h    # Command parser interface
│   └── src/
│       ├── main.c               # Application entry point
│       ├── usb/
│       │   └── usb_cdc.c        # USB CDC implementation
│       ├── led/
│       │   └── led_controller.c # LED control implementation
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
- **ESP32-S3 board** (Freenove ESP32-S3-WROOM recommended)
- **PlatformIO** (for ESP32 firmware)

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

# Build firmware
pio run

# Upload to ESP32
pio run -e freenove_esp32_s3_wroom -t upload

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
7. The onboard LED will now respond to OBS recording state!

## Communication Protocol

Text-based protocol over USB CDC serial (115200 baud, 8N1):

| Command     | Description                    |
|-------------|--------------------------------|
| `LED_ON`    | Turn LED on with the legacy green color |
| `LED_ON:<red>,<green>,<blue>` | Turn LED on with an RGB color (each component 0–255) |
| `LED_OFF`   | Turn LED off (not recording)   |
| `BLINK_FAST`| Blink fast (error state)       |
| `BLINK_SLOW`| Blink slow (idle/disconnected) |
| `STATUS`    | Query current state            |

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

GPL-3.0 - See [LICENSE](LICENSE) for details.
