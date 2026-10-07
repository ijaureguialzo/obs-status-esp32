/**
 * @file protocol_line_buffer.h
 * @brief Line assembly for the byte stream coming from the USB CDC link
 *
 * No FreeRTOS / ESP-IDF dependencies so it can be unit-tested on the host
 * (see test/test_protocol_line_buffer.c).
 */

#ifndef PROTOCOL_LINE_BUFFER_H
#define PROTOCOL_LINE_BUFFER_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "obs_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char buffer[PROTOCOL_MAX_LINE_LENGTH];
    size_t length;
} protocol_line_buffer_t;

/**
 * @brief Reset the buffer (discard a partially received line)
 */
void protocol_line_buffer_reset(protocol_line_buffer_t *lb);

/**
 * @brief Feed raw bytes into the line buffer
 *
 * '\r' is ignored and '\n' terminates a line; every completed line is
 * handed to `handler` (null-terminated, may be NULL). Bytes that would
 * overflow the buffer are dropped until the next line end.
 */
void protocol_line_buffer_feed(protocol_line_buffer_t *lb,
                               const uint8_t *data, size_t len,
                               void (*handler)(const char *line));

#ifdef __cplusplus
}
#endif

#endif /* PROTOCOL_LINE_BUFFER_H */
