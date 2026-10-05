# Spec 04: ESP32 Firmware

## 1. Overview

Embedded firmware for the ESP32 microcontroller that receives commands from the macOS application over USB CDC and controls an onboard LED based on OBS recording state.

## 2. Technology Stack

| Component       | Technology              |
|-----------------|-------------------------|
| Language        | C (ESP-IDF)            |
| Framework       | ESP-IDF v5.2+          |
| Target Boards   | ESP32-S3-DevKit N8R8 (default), Waveshare ESP32-C6-Touch-LCD-1.47 |
| Build System    | PlatformIO             |

## 3. Hardware Configuration

### 3.1 Target Boards

Default: `esp32-s3-dev-kit-n8r8` (PlatformIO environment of the same name).

Alternative: `esp32-c6-touch-lcd-1_47` (Waveshare ESP32-C6-Touch-LCD-1.47).

```ini
[env:esp32-s3-dev-kit-n8r8]
platform = espressif32
board = esp32-s3-dev-kit-n8r8
framework = espidf

[env:esp32-c6-touch-lcd-1_47]
platform = espressif32
board = esp32-c6-touch-lcd-1_47
framework = espidf
```

### 3.2 Pin Mapping

#### ESP32-S3-DevKit N8R8

| Component     | Pin  | Notes                        |
|---------------|------|------------------------------|
| Onboard LED   | GPIO38 | Addressable RGB (WS2812)   |
| USB Device    | N/A  | USB Serial JTAG (native USB) |

#### Waveshare ESP32-C6-Touch-LCD-1.47

| Component          | Pin    | Notes                                  |
|--------------------|--------|----------------------------------------|
| LCD (JD9853, SPI2) | SCLK=GPIO1, MOSI=GPIO2, MISO=GPIO3 | 172x320, ST7789-compatible |
| LCD control        | CS=GPIO14, DC=GPIO15, RST=GPIO22   |                        |
| LCD backlight      | GPIO23 | LEDC PWM, 5 kHz, active-high           |
| Touch (AXS5106L)   | I2C SDA=GPIO18, SCL=GPIO19, RST=GPIO20, INT=GPIO21 | I2C addr 0x63, shared bus with the IMU |
| Onboard LED        | none   | The screen background mirrors the LED color |
| USB Device         | GPIO12/13 | USB Serial JTAG (native USB)        |

**Note**: The ESP32-S3 onboard RGB LED uses the WS2812 protocol and must be
driven with RMT, not as a simple GPIO output. `CONFIG_LED_GPIO_NUM` selects
the data pin; set it to `-1` on boards without an addressable LED (the LED
commands then only affect the display, if present).

`CONFIG_BOARD_HAS_DISPLAY=1` (defined by the C6 environment) compiles in the
display and touch modules; elsewhere they are no-op stubs.

### 3.3 USB Configuration

- **USB Stack**: USB Serial JTAG (native USB, ESP32-S3 and ESP32-C6)
- **Device Class**: CDC-ACM (Communication Device Class - Abstract Control Model)
- **Endpoints**: 
  - CDC Command endpoint (interrupt, optional)
  - CDC Data In (bulk)
  - CDC Data Out (bulk)

## 4. Firmware Architecture

### 4.1 Module Structure

```
esp32-firmware/
├── src/
│   ├── usb/
│   │   └── usb_cdc.c            # USB CDC device driver wrapper
│   ├── led/
│   │   └── led_controller.c     # LED control (WS2812 via RMT)
│   ├── display/
│   │   ├── display_controller.c # LCD control (JD9853 via esp_lcd, display boards only)
│   │   └── font8x8_basic.h      # Public domain 8x8 bitmap font
│   ├── touch/
│   │   └── touch_controller.c   # AXS5106L touch input (display boards only)
│   └── protocol/
│       └── protocol_parser.c    # Command parsing & dispatch
├── include/
│   ├── usb_cdc.h
│   ├── led_controller.h
│   ├── display_controller.h
│   ├── touch_controller.h
│   └── protocol_parser.h
├── components/
│   ├── esp_lcd_jd9853/          # Vendored Waveshare LCD panel driver
│   └── esp_lcd_touch_axs5106/   # Vendored Waveshare touch driver
├── boards/
│   ├── esp32-s3-dev-kit-n8r8.json
│   └── esp32-c6-touch-lcd-1_47.json
├── CMakeLists.txt
├── platformio.ini
└── sdkconfig.<environment>
```

### 4.2 Module Responsibilities

#### `usb_cdc.c/h` – USB CDC Layer
- Initialize USB CDC-ACM device
- Provide `usb_cdc_write()` and `usb_cdc_read()` functions
- Handle connection/disconnection events
- Buffer management (ring buffer)

**API**:
```c
esp_err_t usb_cdc_init(void);
esp_err_t usb_cdc_send(const uint8_t *data, size_t len);
int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout);
bool usb_cdc_is_connected(void);
```

#### `led_controller.c/h` – LED Control Layer
- Initialize LED GPIO/PWM
- Provide `led_on()`, `led_off()`, `led_blink()` functions
- Support both solid and blinking patterns

**API**:
```c
esp_err_t led_init(uint8_t pin);
void led_on(void);
void led_off(void);
void led_blink_fast(void);  // 5Hz
void led_blink_slow(void);  // 1Hz
void led_set_color(uint8_t red, uint8_t green, uint8_t blue);
```

#### `protocol_parser.c/h` – Command Parser
- Parse incoming text commands (terminated by `\n`)
- Dispatch to appropriate handler (LED control)
- Generate response strings
- Handle unknown commands with error responses
- On display boards, mirror the LED color to the screen background and
  handle the `SCENE:<name>` command
- Emit `EVENT:TOGGLE_PAUSE` via `protocol_notify_toggle_pause()` (called by
  the touch controller)

**API**:
```c
esp_err_t protocol_process(const char *line);
// Returns ESP_OK on success, ESP_ERR_NOT_FOUND for unknown commands
void protocol_notify_toggle_pause(void);
```

#### `display_controller.c/h` – Display Control Layer (display boards only)
- Initialize the JD9853 LCD panel (SPI) and LEDC backlight
- Fill the background with the current LED/recording color
- Render the active OBS scene name (8x8 bitmap font, 2x scale, centered,
  automatic contrast color)
- Compiled to no-op stubs when `CONFIG_BOARD_HAS_DISPLAY` is not defined

**API**:
```c
esp_err_t display_init(void);
void display_set_background(uint8_t red, uint8_t green, uint8_t blue);
void display_set_scene(const char *name);
```

#### `touch_controller.c/h` – Touch Input Layer (display boards only)
- Initialize the AXS5106L touch controller (shared I2C bus, 400 kHz)
- Poll every 50 ms; on a tap (rising edge) call
  `protocol_notify_toggle_pause()`
- Compiled to a no-op stub when `CONFIG_BOARD_HAS_DISPLAY` is not defined

**API**:
```c
esp_err_t touch_init(void);
```

### 4.3 Application Flow (`app_main.c`)

```
1. Initialize NVS (if needed for config)
2. Initialize USB CDC
3. Initialize LED (default: BLINK_SLOW)
4. Enter main loop:
   a. Read from USB CDC (blocking, 100ms timeout)
   b. If data received:
      - Buffer into line buffer
      - On '\n', parse and dispatch command
      - Send response
   c. If no data for 10 seconds → BLINK_SLOW (timeout)
```

## 5. State Machine (ESP32 Side)

```
┌──────────┐   USB connected    ┌──────────┐
│  POWERED │ ──────────────────► │  WAIT    │
│          │                     │ (SLOW)   │
└──────────┘                     └────┬─────┘
                                      │
                              macOS sends
                              LED_ON or
                              LED_OFF
                                      ▼
                              ┌──────────────┐
                              │  PROCESSING   │
                              │ (handle cmd)  │
                              └──────┬───────┘
                                     / \
                              ON    /    \    OFF
                                   /      \
                                  ▼        ▼
                         ┌────────────┐  ┌───────┐
                         │  RECORDING │  │  IDLE  │
                         │  (ON)      │  │  (OFF) │
                         └────────────┘  └───────┘
```

## 6. Configuration

### 6.1 Build Flags

```
CONFIG_LED_GPIO_NUM=38        # WS2812 RGB data pin (ESP32-S3); -1 = no LED
CONFIG_BOARD_HAS_DISPLAY=1    # Compile display + touch modules (C6 board)
```

### 6.2 Runtime Config

All other configuration via `sdkconfig` (PlatformIO manages one
`sdkconfig.<environment>` file per environment).

## 7. Error Handling

| Error                  | Behavior                        |
|------------------------|---------------------------------|
| USB enumeration fail   | BLINK_FAST (error pattern)      |
| LED GPIO init fail     | BLINK_SLOW (warning, no LED)    |
| Unknown command        | Reply `ERROR: UNKNOWN_COMMAND`  |
| Bad format            | Reply `ERROR: INVALID_FORMAT`   |

## 8. Build & Flash

```bash
# Build (ESP32-S3, default)
pio run -e esp32-s3-dev-kit-n8r8

# Build (ESP32-C6-Touch-LCD-1.47)
pio run -e esp32-c6-touch-lcd-1_47

# Upload
pio run -e esp32-s3-dev-kit-n8r8 -t upload
pio run -e esp32-c6-touch-lcd-1_47 -t upload

# Or via Make from the repository root
make install BOARD=esp32-c6-touch-lcd-1_47
make install-c6        # shortcut
make install-s3        # shortcut

# Monitor (for debugging)
pio device monitor -b 115200
```

## 9. File Size Targets

| Component  | Limit    | Target   |
|------------|----------|----------|
| Binary     | 512 KB   | < 256 KB |
| Flash      | 4 MB     | < 1 MB   |
| RAM        | 8 MB     | < 256 KB |
