# Spec 03: macOS Application

## 1. Overview

The macOS application serves as the bridge between OBS Studio and the ESP32 hardware. It monitors OBS recording state via WebSocket and relays commands to the ESP32 over USB CDC.

## 2. Technology Stack

| Component       | Technology              |
|-----------------|-------------------------|
| Language        | Swift 5.9+             |
| UI Framework    | SwiftUI                |
| Target macOS    | 14.0 (Sonoma) +        |
| OBS WebSocket   | OBS WebSocket v5 via URLSessionWebSocketTask |
| USB Serial      | libusb / IOKit         |
| Build System    | Xcode / Swift Package  |

## 3. User Interface

### 3.1 Main Window

The app opens with a single window with two tabs or sections:

#### Section A: OBS Connection
- **Host** field: OBS WebSocket host (default: `localhost`)
- **Port** field: OBS WebSocket v5 port (default: `4455`)
- **Password/Token** field: WebSocket authentication token (password field with visibility toggle)
- **Connect/Disconnect** button
- **Status indicator**: Green dot (connected), Red dot (disconnected), Yellow (connecting)
- **Recording indicator**: Large visual indicator showing current OBS recording state

#### Section B: ESP32 Connection
- **Device Selector**: Dropdown showing each USB product description and `/dev/cu.*` port
- **Connect/Disconnect** button for ESP32
- **Status indicator**: Green (connected), Red (disconnected)
- **Last seen** timestamp

#### Visual Recording Indicator
- Large circular LED graphic that mirrors the ESP32 LED state
- Green glow when recording
- Dim/off when not recording

### 3.2 Settings Window (Optional)
- Persistent config: saved in `~/Library/Preferences/com.<bundle-id>.json`
- OBS host, port, token
- Default ESP32 baud rate
- Auto-connect on launch toggle

## 4. Core Services

### 4.1 OBS WebSocket Service

**Responsibilities**:
- Connect/disconnect to OBS Studio via WebSocket
- Authenticate using the OBS WebSocket v5 challenge/response handshake
- Request the initial status with `GetRecordStatus` and subscribe to `RecordStateChanged`
- Handle reconnection with exponential backoff (1s → 30s max)
- Emit `RecordingStateChange` events to the app state

**API**:
```swift
class OBSWebSocketService {
    func connect(host: String, port: Int, token: String) async throws
    func disconnect()
    var recordingState: RecordingState { get }
    var isConnected: Bool { get }
}

enum RecordingState {
    case recording
    case notRecording
    case unknown
}
```

### 4.2 USB CDC Service

**Responsibilities**:
- Enumerate available USB CDC devices on macOS
- Connect to selected ESP32 device
- Send commands (text-based, `\n` terminated)
- Read newline-terminated responses with a two-second timeout
- Handle disconnection and reconnection

**API**:
```swift
class USBCDCService {
    func enumerateDevices() async -> [USBDevice]
    func connect(_ device: USBDevice) async throws
    func disconnect() async
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String
}

struct USBDevice {
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let name: String
    let path: String // e.g., "/dev/cu.usbserial-xxx"
}
```

### 4.3 LED Command Dispatch

LED command dispatch is implemented by `AppViewModel`; it is not a separate
service object. After a USB failure, the selected device is reconnected and
the current OBS recording state is sent again.

**Responsibilities**:
- Translate OBS recording state to ESP32 commands
- Maintain connection state awareness
- Retry after failures by reconnecting to the selected device
- Manage LED state locally for UI consistency

LED-on and LED-off commands are acknowledged by a newline-terminated response.
The service uses a two-second response timeout and serializes access to the
selected USB device.

## 5. App State Management

### 5.1 AppViewModel

Central state manager using `@Observable` (iOS 17+/macOS 14+) pattern:

```swift
@Observable
class AppViewModel {
    var obsConnected: Bool
    var obsRecording: Bool
    var espConnected: Bool
    var availableDevices: [USBDevice]
    var selectedDevice: USBDevice?
    var errorMessage: String?
    
    func connectOBS() async
    func connectESP() async
    func scanDevices() async
}
```

### 5.2 Persistence

Settings saved to:
`~/Library/Preferences/<bundle-id>.json`.

Stored values:
- OBS host and port in the preferences JSON file
- OBS token in the macOS Keychain
- Last selected ESP32 device
- Auto-connect preferences

## 6. macOS Integration

### 6.1 Background Operation
- Option to run as menu bar app (no window)
- `LSUIElement` Info.plist key for daemon mode

### 6.2 Permissions Required
- **Network**: WebSocket connections (local only, no special entitlement)
- **USB**: IOKit access for serial devices (automatic on macOS)

### 6.3 Info.plist Entries
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app needs to connect to OBS Studio on your local machine to monitor recording status.</string>
<key>ITSAppUsesNonExemptEncryption</key>
<false>
```

## 7. File Structure

```
macos-app/
├── Package.swift
├── obs-status-macos-ui/
│   ├── App/
│   │   ├── ObsStatusApp.swift          # @main app entry
│   │   └── ObsStatusMenuBar.swift      # Optional menu bar integration
│   ├── UI/
│   │   ├── ContentView.swift           # Main window
│   │   ├── OBSConnectionView.swift     # OBS config panel
│   │   ├── ESP32ConnectionView.swift   # ESP32 config panel
│   │   ├── LEDIndicatorView.swift      # Visual recording indicator
│   ├── Services/
│   │   ├── OBSWebSocketService.swift   # OBS WebSocket v5 client
│   │   ├── USBCDCService.swift         # USB serial communication
│   ├── Models/
│   │   ├── OBSConfig.swift             # OBS connection config
│   │   ├── USBDevice.swift             # USB device model
│   │   └── AppSettings.swift           # Persistent settings
│   ├── Extensions/
│   │   └── AsyncStream+Extensions.swift
│   ├── Assets.xcassets/
│   └── Resources/
│       └── Info.plist
└── obs-status-macos-ui.xcodeproj/
```
