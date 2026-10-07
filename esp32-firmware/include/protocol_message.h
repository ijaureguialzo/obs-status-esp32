/**
 * @file protocol_message.h
 * @brief Pure command-line parsing for the text protocol
 *
 * No FreeRTOS / ESP-IDF dependencies so it can be unit-tested on the host
 * (see test/test_protocol_message.c).
 */

#ifndef PROTOCOL_MESSAGE_H
#define PROTOCOL_MESSAGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PROTOCOL_MSG_LED_ON,
    PROTOCOL_MSG_LED_OFF,
    PROTOCOL_MSG_BLINK_FAST,
    PROTOCOL_MSG_BLINK_SLOW,
    PROTOCOL_MSG_STATUS,
    PROTOCOL_MSG_SCENE,
} protocol_message_type_t;

typedef struct {
    protocol_message_type_t type;
    uint8_t red;       /* PROTOCOL_MSG_LED_ON with an explicit color */
    uint8_t green;
    uint8_t blue;
    bool has_color;    /* "LED_ON:r,g,b" -> true; bare "LED_ON" -> false */
    const char *scene; /* PROTOCOL_MSG_SCENE: points into the input line */
} protocol_message_t;

typedef enum {
    PROTOCOL_MSG_OK = 0,
    PROTOCOL_MSG_INVALID_FORMAT,  /* known command, malformed arguments */
    PROTOCOL_MSG_UNKNOWN_COMMAND, /* no command matched */
} protocol_message_result_t;

/**
 * @brief Parse one command line (line ending already stripped)
 * @param line Null-terminated command line
 * @param out  Parsed message; for SCENE, `scene` points into `line` and is
 *             valid for as long as `line` is
 * @return PROTOCOL_MSG_OK on success, one of the error results otherwise
 */
protocol_message_result_t protocol_message_parse(const char *line, protocol_message_t *out);

#ifdef __cplusplus
}
#endif

#endif /* PROTOCOL_MESSAGE_H */
