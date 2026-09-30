/**
 * @file protocol_parser.c
 * @brief Command parser for the text-based protocol
 */

#include "protocol_parser.h"
#include "usb_cdc.h"
#include "led_controller.h"
#include "obs_protocol.h"
#include "freertos/FreeRTOS.h"
#include <stdio.h>
#include <string.h>

#define RESPONSE_BUFFER_SIZE 128

static char s_response_buffer[RESPONSE_BUFFER_SIZE];

static bool parse_led_on_color(const char *command, uint8_t *red, uint8_t *green, uint8_t *blue);
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

    if (strcmp(trimmed, PROTOCOL_TXT_LED_ON) == 0) {
        led_on();
        send_response(PROTOCOL_TXT_OK);
        return ESP_OK;

    } else if (strncmp(trimmed, PROTOCOL_TXT_LED_ON_COLOR_PREFIX,
                       strlen(PROTOCOL_TXT_LED_ON_COLOR_PREFIX)) == 0) {
        uint8_t red;
        uint8_t green;
        uint8_t blue;
        if (!parse_led_on_color(trimmed, &red, &green, &blue)) {
            send_response(PROTOCOL_TXT_ERROR_FORMAT);
            return ESP_ERR_INVALID_ARG;
        }
        led_set_color(red, green, blue);
        led_on();
        send_response(PROTOCOL_TXT_OK);
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_LED_OFF) == 0) {
        led_off();
        send_response(PROTOCOL_TXT_OK);
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_BLINK_FAST) == 0) {
        led_blink_fast();
        send_response(PROTOCOL_TXT_OK);
        return ESP_OK;

    } else if (strcmp(trimmed, PROTOCOL_TXT_BLINK_SLOW) == 0) {
        led_blink_slow();
        send_response(PROTOCOL_TXT_OK);
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

static bool parse_led_on_color(const char *command, uint8_t *red, uint8_t *green, uint8_t *blue)
{
    unsigned int parsed_red;
    unsigned int parsed_green;
    unsigned int parsed_blue;
    char trailing;
    const char *arguments = command + strlen(PROTOCOL_TXT_LED_ON_COLOR_PREFIX);

    if (sscanf(arguments, "%u,%u,%u%c", &parsed_red, &parsed_green, &parsed_blue, &trailing) != 3 ||
        parsed_red > UINT8_MAX || parsed_green > UINT8_MAX || parsed_blue > UINT8_MAX) {
        return false;
    }

    *red = (uint8_t)parsed_red;
    *green = (uint8_t)parsed_green;
    *blue = (uint8_t)parsed_blue;
    return true;
}

static void send_response(const char *response)
{
    snprintf(s_response_buffer, RESPONSE_BUFFER_SIZE, "%s" PROTOCOL_LINE_END, response);
    usb_cdc_send((const uint8_t *)s_response_buffer, strlen(s_response_buffer));
}
