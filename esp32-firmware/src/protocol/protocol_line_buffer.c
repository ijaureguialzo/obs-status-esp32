/**
 * @file protocol_line_buffer.c
 * @brief Line assembly for the byte stream coming from the USB CDC link
 */

#include "protocol_line_buffer.h"

#include <string.h>

void protocol_line_buffer_reset(protocol_line_buffer_t *lb)
{
    if (lb != NULL) {
        lb->length = 0;
    }
}

void protocol_line_buffer_feed(protocol_line_buffer_t *lb,
                               const uint8_t *data, size_t len,
                               void (*handler)(const char *line))
{
    if (lb == NULL || data == NULL || len == 0) {
        return;
    }

    for (size_t i = 0; i < len; i++) {
        const uint8_t byte = data[i];

        if (byte == '\n') {
            if (lb->length > 0) {
                lb->buffer[lb->length] = '\0';
                lb->length = 0;
                if (handler != NULL) {
                    handler(lb->buffer);
                }
            }
        } else if (byte != '\r') {
            if (lb->length < PROTOCOL_MAX_LINE_LENGTH - 1) {
                lb->buffer[lb->length++] = (char)byte;
            }
        }
    }
}
