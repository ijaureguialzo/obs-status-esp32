# Spec 05: Deployment & Distribution

## 1. macOS Application Distribution

### 1.1 Build Requirements
- Xcode 15.0+
- macOS 14.0+ SDK
- Swift 5.9+

### 1.2 App Signing & Notarization
```bash
# Code sign
codesign --sign "Developer ID Application: Your Name" \
    --options runtime \
    --timestamp \
    obs-status.app

# Notarize
xcrun notarytool submit obs-status.app \
    --apple-id "your@apple.id" \
    --password "@keychain:notary-password" \
    --team-id "YOUR_TEAM_ID" \
    --staple
```

### 1.3 Distribution Formats
- **DMG**: Disk image for manual install
- **PKG**: Installer package (optional)
- **Homebrew Cask**: Future distribution via `brew install --cask obs-status`

### 1.4 App Bundle Configuration

**Info.plist**:
```xml
<key>CFBundleExecutable</key>
<string>obs-status</string>
<key>CFBundleIdentifier</key>
<string>com.<your-domain>.obs-status</string>
<key>CFBundleName</key>
<string>ObsStatus</string>
<key>CFBundleVersion</key>
<string>1</string>
<key>CFBundleShortVersionString</key>
<string>1.0.0</string>
<key>LSMinimumSystemVersion</key>
<string>14.0</string>
```

## 2. ESP32 Firmware Distribution

### 2.1 Build Targets

```bash
# Production build
pio run -e freenove_esp32_s3_wroom -e esp32-s3-devkitc-1

# Custom board (add to platformio.ini)
[env:<board-name>]
platform = espressif32
board = <board-name>
framework = espidf
```

### 2.2 Flash Images

Output of `pio run`:
- `firmware.bin` – Raw binary for flashing
- `firmware.partitions.bin` – Partition table

### 2.3 Flash Commands (Manual)
```bash
# Via esptool.py
esptool.py --chip esp32s3 --port /dev/cu.usbserial-* \
    write_flash 0x0 .pio/build/<env>/firmware.bin

# With partitions
esptool.py --chip esp32s3 --port /dev/cu.usbserial-* \
    write_flash --flash_mode qio --flash_size 4MB 0x0 firmware.bin 0x8000 partitions.bin
```

## 3. Installation Guide

### 3.1 Prerequisites
- OBS Studio installed with **obs-websocket** plugin
- ESP32 board connected via USB-C cable
- macOS 14.0+ (for the desktop app)

### 3.2 OBS Setup
1. Install obs-websocket plugin for OBS Studio
   - Download from: https://github.com/obsproject/obs-websocket
   - Follow installation instructions for your OS
2. Note the WebSocket port (default: 4444)
3. Set an authentication token (recommended)

### 3.3 macOS App Installation
1. Download the DMG file
2. Drag ObsStatus.app to Applications folder
3. First launch: Gatekeeper may show warning → Right-click → Open
4. Launch the app
5. Configure OBS connection (host, port, token)
6. Connect to OBS
7. Select your ESP32 device from the dropdown
8. Connect to ESP32
9. Observe the LED respond to OBS recording state!

### 3.4 ESP32 Flashing (First Time)
1. Connect ESP32 via USB-C
2. Identify the serial port: `ls /dev/cu.*`
3. Flash the firmware: `pio run -e freenove_esp32_s3_wroom -t upload`
4. Verify: LED should blink slowly (waiting for commands)

## 4. Troubleshooting

| Issue                    | Solution                                  |
|--------------------------|-------------------------------------------|
| App can't find OBS       | Ensure obs-websocket plugin is installed  |
| ESP32 not showing up     | Try different USB cable (data, not charge-only) |
| LED doesn't respond      | Check LED pin in sdkconfig matches hardware |
| macOS permission denied  | Grant Serial Port access in System Settings |
| WebSocket connection fails| Verify obs-websocket plugin is running in OBS |

## 5. Versioning

Semantic Versioning: `MAJOR.MINOR.PATCH`

- **Major**: Breaking changes to protocol or API
- **Minor**: New features (backward compatible)
- **Patch**: Bug fixes

Both macOS app and ESP32 firmware share the same version number for simplicity.
