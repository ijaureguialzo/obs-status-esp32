/**
 * @file protocol_parser.c
 * @brief Command parser for the text-based protocol
 */

#include "protocol_parser.h"
#include "usb_cdc.h"
#include "led_controller.h"
#include "obs_protocol.h"
#include "freertos/FreeRTOS.h"
#include <string.h>

#define RESPONSE_BUFFER_SIZE 128

static char s_response_buffer[RESPONSE_BUFFER_SIZE];
static char s_line_buffer[PROTOCOL_MAX_LINE_LENGTH];
static size_t s_line_length = 0;

esp_err_t protocol_init(void)
{
    s_line_length = 0;
    memset(s_line_buffer, 0, sizeof(s_line_buffer));
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

    if (strcmp(trimmed, PROTOCOL_TXT_LED_ON) == 0) {
        led_on();
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_OK);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_LED_OFF) == 0) {
        led_off();
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_OK);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_BLINK_FAST) == 0) {
        led_blink_fast();
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_OK);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_BLINK_SLOW) == 0) {
        led_blink_slow();
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_OK);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_STATUS) == 0) {
        const char *led_state = led_is_on() ? "ON" : "OFF";
        const char *usb_state = usb_cdc_is_connected() ? "CONNECTED" : "DISCONNECTED";

        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE,
                 PROTOCOL_STATUS_FORMAT PROTOCOL_LINE_END, led_state, usb_state, 0);

        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_OK;

    } else {
        snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE,
                 "%s" PROTOCOL_LINE_END, PROTOCOL_TXT_ERROR_UNKNOWN);
        usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
        return ESP_ERR_NOT_FOUND;
    }
}
