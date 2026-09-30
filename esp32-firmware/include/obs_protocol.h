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

// ==========================
// Text Protocol Strings
// ==========================

#define PROTOCOL_TXT_LED_ON      "LED_ON"
#define PROTOCOL_TXT_LED_OFF     "LED_OFF"
#define PROTOCOL_TXT_BLINK_FAST  "BLINK_FAST"
#define PROTOCOL_TXT_BLINK_SLOW  "BLINK_SLOW"
#define PROTOCOL_TXT_STATUS      "STATUS"

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

// Format: "STATUS:LED=<state>|OBS=<state>|ERROR=<code>"
#define PROTOCOL_STATUS_FORMAT "STATUS:LED=%s|OBS=%s|ERROR=%d"

#endif // OBS_PROTOCOL_H
