/**
 * @file protocol_message.c
 * @brief Pure command-line parsing for the text protocol
 *
 * Kept dependency-free (obs_protocol.h + stdio only) so it can be
 * unit-tested on the host with PlatformIO's native test environment.
 */

#include "protocol_message.h"

#include "obs_protocol.h"

#include <stdio.h>
#include <string.h>

protocol_message_result_t protocol_message_parse(const char *line, protocol_message_t *out)
{
    if (line == NULL || out == NULL) {
        return PROTOCOL_MSG_UNKNOWN_COMMAND;
    }

    out->type = PROTOCOL_MSG_LED_OFF;
    out->red = 0;
    out->green = 0;
    out->blue = 0;
    out->has_color = false;
    out->scene = NULL;

    if (strcmp(line, PROTOCOL_TXT_LED_ON) == 0) {
        out->type = PROTOCOL_MSG_LED_ON;
        return PROTOCOL_MSG_OK;
    }

    if (strncmp(line, PROTOCOL_TXT_LED_ON_COLOR_PREFIX,
                strlen(PROTOCOL_TXT_LED_ON_COLOR_PREFIX)) == 0) {
        unsigned int red;
        unsigned int green;
        unsigned int blue;
        char trailing;
        const char *arguments = line + strlen(PROTOCOL_TXT_LED_ON_COLOR_PREFIX);

        if (sscanf(arguments, "%u,%u,%u%c", &red, &green, &blue, &trailing) != 3 ||
            red > UINT8_MAX || green > UINT8_MAX || blue > UINT8_MAX) {
            return PROTOCOL_MSG_INVALID_FORMAT;
        }

        out->type = PROTOCOL_MSG_LED_ON;
        out->has_color = true;
        out->red = (uint8_t)red;
        out->green = (uint8_t)green;
        out->blue = (uint8_t)blue;
        return PROTOCOL_MSG_OK;
    }

    if (strcmp(line, PROTOCOL_TXT_LED_OFF) == 0) {
        out->type = PROTOCOL_MSG_LED_OFF;
        return PROTOCOL_MSG_OK;
    }

    if (strcmp(line, PROTOCOL_TXT_BLINK_FAST) == 0) {
        out->type = PROTOCOL_MSG_BLINK_FAST;
        return PROTOCOL_MSG_OK;
    }

    if (strcmp(line, PROTOCOL_TXT_BLINK_SLOW) == 0) {
        out->type = PROTOCOL_MSG_BLINK_SLOW;
        return PROTOCOL_MSG_OK;
    }

    if (strcmp(line, PROTOCOL_TXT_STATUS) == 0) {
        out->type = PROTOCOL_MSG_STATUS;
        return PROTOCOL_MSG_OK;
    }

    if (strncmp(line, PROTOCOL_TXT_SCENE_PREFIX, strlen(PROTOCOL_TXT_SCENE_PREFIX)) == 0) {
        out->type = PROTOCOL_MSG_SCENE;
        out->scene = line + strlen(PROTOCOL_TXT_SCENE_PREFIX);
        return PROTOCOL_MSG_OK;
    }

    return PROTOCOL_MSG_UNKNOWN_COMMAND;
}
