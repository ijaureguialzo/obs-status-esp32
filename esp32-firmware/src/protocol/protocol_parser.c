/**
 * @file protocol_parser.c
 * @brief Command parser for the text-based protocol
 */

#include "protocol_parser.h"
#include "usb_cdc.h"
#include "led_controller.h"
#include "display_controller.h"
#include "protocol_message.h"
#include "obs_protocol.h"
#include <stdio.h>
#include <string.h>

#define RESPONSE_BUFFER_SIZE 128

/* Screen backgrounds used to mirror the LED state on boards with a display */
#define DISPLAY_COLOR_RECORDING_DEFAULT_G 255
#define DISPLAY_COLOR_OFF      0, 0, 0
#define DISPLAY_COLOR_ERROR    255, 128, 0
#define DISPLAY_COLOR_IDLE     32, 32, 32

static char s_response_buffer[RESPONSE_BUFFER_SIZE];

static void send_response(const char *response);

esp_err_t protocol_init(void)
{
    memset(s_response_buffer, 0, sizeof(s_response_buffer));

    return ESP_OK;
}

esp_err_t protocol_process(const char *line)
{
    if (line == NULL || line[0] == '\0') {
        return ESP_OK;
    }

    char trimmed[PROTOCOL_MAX_LINE_LENGTH];
    strncpy(trimmed, line, sizeof(trimmed) - 1);
    trimmed[sizeof(trimmed) - 1] = '\0';

    size_t len = strlen(trimmed);
    while (len > 0 && (trimmed[len - 1] == '\n' || trimmed[len - 1] == '\r' ||
            trimmed[len - 1] == ' ' || trimmed[len - 1] == '\t')) {
        trimmed[--len] = '\0';
    }

    protocol_message_t message;
    switch (protocol_message_parse(trimmed, &message)) {
    case PROTOCOL_MSG_OK:
        switch (message.type) {
        case PROTOCOL_MSG_LED_ON:
            if (message.has_color) {
                led_set_color(message.red, message.green, message.blue);
                display_set_background(message.red, message.green, message.blue);
            } else {
                display_set_background(0, DISPLAY_COLOR_RECORDING_DEFAULT_G, 0);
            }
            led_on();
            send_response(PROTOCOL_TXT_OK);
            return ESP_OK;

        case PROTOCOL_MSG_LED_OFF:
            led_off();
            display_set_background(DISPLAY_COLOR_OFF);
            send_response(PROTOCOL_TXT_OK);
            return ESP_OK;

        case PROTOCOL_MSG_BLINK_FAST:
            led_blink_fast();
            display_set_background(DISPLAY_COLOR_ERROR);
            send_response(PROTOCOL_TXT_OK);
            return ESP_OK;

        case PROTOCOL_MSG_BLINK_SLOW:
            led_blink_slow();
            display_set_background(DISPLAY_COLOR_IDLE);
            send_response(PROTOCOL_TXT_OK);
            return ESP_OK;

        case PROTOCOL_MSG_STATUS: {
            const char *led_state = led_is_on() ? "ON" : "OFF";
            const char *usb_state = usb_cdc_is_connected() ? "CONNECTED" : "DISCONNECTED";

            snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE,
                     PROTOCOL_STATUS_FORMAT PROTOCOL_LINE_END, led_state, usb_state, 0,
                     FIRMWARE_VERSION);

            usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
            return ESP_OK;
        }

        case PROTOCOL_MSG_SCENE:
            display_set_scene(message.scene);
            send_response(PROTOCOL_TXT_OK);
            return ESP_OK;
        }
        /* Not reachable: PROTOCOL_MSG_OK always carries a valid type */
        return ESP_OK;

    case PROTOCOL_MSG_INVALID_FORMAT:
        send_response(PROTOCOL_TXT_ERROR_FORMAT);
        return ESP_ERR_INVALID_ARG;

    case PROTOCOL_MSG_UNKNOWN_COMMAND:
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE,
                 "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_ERROR_UNKNOWN);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_ERR_NOT_FOUND;
    }

    /* The switch covers every protocol_message_result_t value; this only
     * silences -Werror=return-type for out-of-range values. */
    return ESP_ERR_NOT_FOUND;
}

static void send_response(const char *response)
{
    snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, response);
    usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
}

void protocol_notify_toggle_pause(void)
{
    static const char event[] = PROTOCOL_TXT_EVENT_TOGGLE_PAUSE PROTOCOL_LINE_END;
    usb_cdc_send((const uint8_t *)event, sizeof(event) - 1);
}
