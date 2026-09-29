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
│                     │  ws:4444│                      │  USB    │                 │
│ Recording State     │         │  • Connect to OBS    │  CDC    │ LED Control     │
│ (via WebSocket)     │         │  • Connect to ESP32  │◄───────►│  (onboard LED)  │
└─────────────────────┘         └──────────────────────┘         └─────────────────┘
```

## Implementation Status

| Component       | Status  | Notes                                     |
|-----------------|---------|---------------------------------------------|
| macOS App (UI)  | ✅ Done | Complete SwiftUI with all panels            |
| macOS WebSocket | ✅ Done | Custom WebSocket client using BSD sockets   |
| macOS USB CDC   | ✅ Done | IOKit-based serial port enumeration/control |
| ESP32 Firmware  | ✅ Done | Full structure with TODO markers            |
| Protocol Parser | ✅ Done | Text command parsing and dispatch           |
| LED Controller  | ✅ Done | GPIO + FreeRTOS timer for blink patterns    |
| USB CDC (ESP32) | ⚠️ TODO | See USB_CDC notes in source code            |

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
│   ├── Package.swift               # Swift Package
│   ├── Resources/
│   │   └── Info.plist              # App configuration
│   └── Sources/
│       ├── App/
│       │   └── ObsStatusApp.swift   # @main entry point
│       ├── UI/
│       │   ├── ContentView.swift           # Main window layout
│       │   ├── OBSConnectionView.swift     # OBS config panel
│       │   ├── ESP32ConnectionView.swift   # ESP32 config panel
│       │   └── LEDIndicatorView.swift      # Visual recording indicator
│       ├── Services/
│       │   ├── OBSWebSocketService.swift   # WebSocket client (custom BSD socket impl)
│       │   └── USBCDCService.swift         # USB serial via IOKit
│       ├── Models/
│       │   ├── AppViewModel.swift          # Central state manager
│       │   ├── OBSConfig.swift             # OBS config model
│       │   ├── USBDevice.swift             # USB device model
│       │   ├── AppSettings.swift           # Persistent settings
│       │   └── ObsProtocol.swift           # Protocol definitions
│       └── Extensions/
│           └── AsyncStream+Extensions.swift
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

**Crear el proyecto Xcode (una sola vez):**

1. Abre Xcode
2. Ve a `File > New > Project...`
3. Selecciona `macOS > App` y pulsa `Next`
4. Configura:
   - **Product Name**: `obs-status-macos-ui`
   - **Bundle Identifier**: `com.obsstatus.app` (o tu dominio)
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
5. Guarda el proyecto en la carpeta `macos-app/` (fuera de obs-status-macos-ui)
6. En el proyecto creado:
   - Arrastra los archivos de `obs-status-macos-ui/Sources/` al grupo `Sources`
   - Arrastra `obs-status-macos-ui/Resources/Info.plist` al grupo `Resources`
   - En Build Settings, establece:
     - ` macOS Deployment Target` a `14.0`
     - `Swift Version` a `5.9`

**O usar XcodeGen (alternativa):**

```bash
brew install xcodegen
cd macos-app
xcodegen generate
```

Con un archivo `codegen.yml`:
```yaml
name: obs-status-macos-ui
targets:
  obs-status-macos-ui:
    type: application
    platform: macOS
    sources: [obs-status-macos-ui/Sources]
    settings:
      base:
        macOSXDeploymentTarget: 14.0
        SWIFT_VERSION: 5.9
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
| `LED_ON`    | Turn LED on (recording)        |
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
