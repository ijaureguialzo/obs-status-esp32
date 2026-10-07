//
//  obs_protocol.h
//  Protocol definitions for macOS <-> ESP32 communication
//

#ifndef OBS_PROTOCOL_H
#define OBS_PROTOCOL_H

#include <stdint.h>

// ==========================
// Command IDs (binary protocol for future extension)
// ==========================

#define PROTOCOL_CMD_LED_ON     0x01
#define PROTOCOL_CMD_LED_OFF    0x02
#define PROTOCOL_CMD_BLINK_FAST 0x03
#define PROTOCOL_CMD_BLINK_SLOW 0x04
#define PROTOCOL_CMD_STATUS     0x05
#define PROTOCOL_CMD_SCENE      0x06

// ==========================
// Text Protocol Strings
// ==========================

#define PROTOCOL_TXT_LED_ON      "LED_ON"
#define PROTOCOL_TXT_LED_ON_COLOR_PREFIX "LED_ON:"
#define PROTOCOL_TXT_LED_OFF     "LED_OFF"
#define PROTOCOL_TXT_BLINK_FAST  "BLINK_FAST"
#define PROTOCOL_TXT_BLINK_SLOW  "BLINK_SLOW"
#define PROTOCOL_TXT_STATUS      "STATUS"
#define PROTOCOL_TXT_SCENE_PREFIX "SCENE:"

// ==========================
// Event Strings (ESP32 -> macOS, unsolicited)
// ==========================

#define PROTOCOL_TXT_EVENT_TOGGLE_PAUSE "EVENT:TOGGLE_PAUSE"

// ==========================
// Response Strings
// ==========================

#define PROTOCOL_TXT_OK          "OK"
#define PROTOCOL_TXT_ERROR_UNKNOWN "ERROR: UNKNOWN_COMMAND"
#define PROTOCOL_TXT_ERROR_FORMAT  "ERROR: INVALID_FORMAT"

// ==========================
// Configuration Defaults
// ==========================

#define PROTOCOL_BAUD_RATE        115200
#define PROTOCOL_LINE_END        "\n"
#define PROTOCOL_MAX_LINE_LENGTH  128
#define PROTOCOL_TIMEOUT_MS      10000  // Disconnect timeout

// ==========================
// Status Response Format
// ==========================

// Format: "STATUS:LED=<state>|USB=<state>|ERROR=<code>|FW=<version>"
#define PROTOCOL_STATUS_FORMAT "STATUS:LED=%s|USB=%s|ERROR=%d|FW=%s"

// ==========================
// Firmware Version
// ==========================

// Reported in the STATUS response; overridable at build time
// (build_flags: -DFIRMWARE_VERSION="x.y.z")
#ifndef FIRMWARE_VERSION
#define FIRMWARE_VERSION "1.0.0"
#endif

#endif // OBS_PROTOCOL_H
