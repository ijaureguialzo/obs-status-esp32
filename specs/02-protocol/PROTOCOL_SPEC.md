# Spec 02: Communication Protocol

## 1. Overview

This document defines the bidirectional communication protocol between the macOS Application and the ESP32 firmware over USB CDC (Virtual Serial Port).

## 2. Transport Layer

- **Interface**: USB CDC-ACM (Virtual Serial Port)
- **Baud Rate**: 115200 (fixed)
- **Data Format**: 8N1 (8 data bits, No parity, 1 stop bit)
- **Line Ending**: `\n` (newline, 0x0A)
- **Encoding**: UTF-8

## 3. Command Format

All commands are plain-text, case-sensitive, terminated with `\n`:

```
<COMMAND> <ARGS>\n
```

### 3.1 Command: `LED_ON`

Turns the onboard LED ON (solid).

```
LED_ON\n
```

**Response**: `OK\n` on success.

**Use case**: OBS is recording.

To choose the recording color, send the RGB components as decimal values from
0 through 255:

```
LED_ON:<red>,<green>,<blue>\n
```

For example, `LED_ON:255,0,128\n` lights the LED magenta. The legacy
`LED_ON\n` command remains supported and uses the default green color.

### 3.2 Command: `LED_OFF`

Turns the onboard LED OFF.

```
LED_OFF\n
```

**Response**: `OK\n` on success.

**Use case**: OBS is not recording.

### 3.3 Command: `BLINK_FAST`

Blinks the LED at high frequency (5Hz).

```
BLINK_FAST\n
```

**Response**: `OK\n` on success.

**Use case**: Error state – ESP32 not receiving commands from macOS app.

### 3.4 Command: `BLINK_SLOW`

Blinks the LED at low frequency (1Hz).

```
BLINK_SLOW\n
```

**Response**: `OK\n` on success.

**Use case**: Warning state – macOS app is connected to OBS but recording is idle.

### 3.5 Command: `STATUS`

Requests the current status from the ESP32.

```
STATUS\n
```

**Response**: `STATUS:LED=<state>|USB=<usbState>|ERROR=<errorCode>\n`

Where:
- `LED`: `ON` / `OFF`
- `USB`: `CONNECTED` / `DISCONNECTED` (USB host connection state; the ESP32 has no knowledge of OBS)
- `errorCode`: `0` (none) or error code integer

**Example**: `STATUS:LED=ON|USB=CONNECTED|ERROR=0\n`

## 4. Error Responses

Format: `ERROR: <description>\n`

Examples:
- `ERROR: UNKNOWN_COMMAND\n` – Command not recognized
- `ERROR: INVALID_FORMAT\n` – Malformed command
- `ERROR: BAD_CHECKSUM\n` – (Future: CRC verification failure)

## 5. State Machine

```
                    ┌─────────────┐
                    │   BOOT      │
                    │ (BLINK_SLOW)│
                    └──────┬──────┘
                           │
               ┌───────────┘
               │ macOS app connects via USB CDC
               ▼
         ┌──────────────┐
         │ IDLE (OFF)  │ ◄───────────────────┐
         └──────┬───────┘                    │
                │ Receive LED_ON              │ Receive LED_OFF
                ▼                            │
         ┌──────────────┐                    │
         │ RECORDING    │                    │
         │ (LED ON)    │                    │
         └──────┬───────┘                    │
                │ Receive LED_OFF             │
                ▼                            │
         ┌──────────────┐                    │
         │ IDLE (OFF)  │────────────────────┘
         └──────────────┘
```

## 6. Timeout Handling

- If no command received from macOS app within 10 seconds → BLINK_SLOW (disconnected)
- If macOS app receives no response to `STATUS` within 2 seconds → mark ESP32 as disconnected

## 7. Future Extensions (Reserved)

- `BRIGHTNESS <0-255>` – Set PWM brightness
- `PATTERN <name>` – Load predefined LED pattern
- `SET_NAME <string>` – Set device name for identification
