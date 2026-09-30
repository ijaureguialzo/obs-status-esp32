# Spec 04: ESP32 Firmware

## 1. Overview

Embedded firmware for the ESP32 microcontroller that receives commands from the macOS application over USB CDC and controls an onboard LED based on OBS recording state.

## 2. Technology Stack

| Component       | Technology              |
|-----------------|-------------------------|
| Language        | C (ESP-IDF)            |
| Framework       | ESP-IDF v5.2+          |
| Target Board    | Freenove ESP32-S3-WROOM (configurable) |
| Build System    | PlatformIO             |

## 3. Hardware Configuration

### 3.1 Target Board

Default: `freenove_esp32_s3_wroom`

```ini
[env:freenove_esp32_s3_wroom]
platform = espressif32
board = freenove_esp32_s3_wroom
framework = espidf
```

### 3.2 Pin Mapping

| Component     | Pin  | Notes                        |
|---------------|------|------------------------------|
| Onboard LED   | GPIO48 | Addressable RGB (WS2812, ESP32-S3-DevKitC-1 N8R8) |
| USB Device    | N/A  | Native USB (USBD)           |

**Note**: The ESP32-S3-DevKitC-1 onboard RGB LED uses the WS2812 protocol and
must be driven with RMT, not as a simple GPIO output. `CONFIG_LED_GPIO_NUM`
selects the data pin for other boards with a compatible addressable RGB LED.

### 3.3 USB Configuration

- **USB Stack**: Native USB (not USB-OTG)
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
│   │   └── usb_cdc.c/h         # USB CDC device driver wrapper
│   ├── led/
│   │   └── led_controller.c/h  # LED control (GPIO/PWM)
│   └── protocol/
│       └── protocol_parser.c/h  # Command parsing & dispatch
├── include/
│   ├── usb_cdc.h
│   ├── led_controller.h
│   └── protocol_parser.h
├── components/
│   └── (optional custom components)
├── main/
│   └── app_main.c              # Application entry point
├── CMakeLists.txt
├── platformio.ini
└── sdkconfig
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

**API**:
```c
esp_err_t protocol_process(const char *line);
// Returns ESP_OK on success, ESP_ERR_NOT_FOUND for unknown commands
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

### 6.1 Kconfig Options

```
CONFIG_LED_GPIO_NUM=48        # WS2812 RGB data pin on ESP32-S3-DevKitC-1
CONFIG_USB_CDC_BAUD_RATE=115200
CONFIG_COMMAND_TIMEOUT_MS=10000  # Disconnect timeout
```

### 6.2 Runtime Config

All configuration via `sdkconfig` (PlatformIO manages this).

## 7. Error Handling

| Error                  | Behavior                        |
|------------------------|---------------------------------|
| USB enumeration fail   | BLINK_FAST (error pattern)      |
| LED GPIO init fail     | BLINK_SLOW (warning, no LED)    |
| Unknown command        | Reply `ERROR: UNKNOWN_COMMAND`  |
| Bad format            | Reply `ERROR: INVALID_FORMAT`   |

## 8. Build & Flash

```bash
# Build
pio run -e freenove_esp32_s3_wroom

# Upload
pio run -e freenove_esp32_s3_wroom -t upload

# Monitor (for debugging)
pio device monitor -b 115200
```

## 9. File Size Targets

| Component  | Limit    | Target   |
|------------|----------|----------|
| Binary     | 512 KB   | < 256 KB |
| Flash      | 4 MB     | < 1 MB   |
| RAM        | 8 MB     | < 256 KB |
