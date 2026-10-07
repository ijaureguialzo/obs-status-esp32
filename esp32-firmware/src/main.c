/**
 * @file app_main.c
 * @brief Main application entry point for ObsStatus ESP32 firmware
 */

#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"

#include "usb_cdc.h"
#include "led_controller.h"
#include "display_controller.h"
#include "touch_controller.h"
#include "protocol_parser.h"
#include "protocol_line_buffer.h"
#include "obs_protocol.h"

static const char *TAG = "obs-status";

#ifndef CONFIG_LED_GPIO_NUM
#define CONFIG_LED_GPIO_NUM 38
#endif

#define APP_TASK_STACK_SIZE 4096
#define APP_TASK_PRIORITY 5
#define USB_RECV_TIMEOUT_MS 100
#define DISCONNECT_TIMEOUT_MS 10000

static TickType_t s_last_command_time = 0;

static void handle_protocol_line(const char *line)
{
    /* Kept at DEBUG: log output and protocol traffic share the USB console,
     * and the host polls STATUS every 2 s. */
    ESP_LOGD(TAG, "Received command: %s", line);
    protocol_process(line);
    s_last_command_time = xTaskGetTickCount();
}

static void app_task(void *pv_parameters)
{
    (void)pv_parameters;

    ESP_LOGI(TAG, "ObsStatus firmware starting");

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_TYPE_MISMATCH) {
        ESP_LOGW(TAG, "NVS partition issue, erasing and retrying");
        nvs_flash_erase();
        nvs_flash_init();
    }

    ESP_LOGI(TAG, "Initializing USB Serial JTAG");
    ret = usb_cdc_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize USB: %s", esp_err_to_name(ret));
    }

#if CONFIG_LED_GPIO_NUM >= 0
    ESP_LOGI(TAG, "Initializing LED on GPIO%d", CONFIG_LED_GPIO_NUM);
    ret = led_init(CONFIG_LED_GPIO_NUM);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize LED: %s", esp_err_to_name(ret));
    }
#else
    ESP_LOGI(TAG, "No onboard LED on this board - LED commands affect the display only");
#endif

    ret = display_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize display: %s", esp_err_to_name(ret));
    }

    ret = touch_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize touch: %s", esp_err_to_name(ret));
    }

    ret = protocol_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize protocol parser");
    }

    led_blink_slow();

    char recv_buffer[PROTOCOL_MAX_LINE_LENGTH];
    protocol_line_buffer_t line;
    protocol_line_buffer_reset(&line);
    s_last_command_time = xTaskGetTickCount();
    bool idle_mode = false;

    ESP_LOGI(TAG, "Entering main loop (waiting for commands)");

    while (1) {
        int bytes_read = usb_cdc_recv((uint8_t *)recv_buffer,
                                       sizeof(recv_buffer) - 1,
                                       pdMS_TO_TICKS(USB_RECV_TIMEOUT_MS));

        if (bytes_read > 0) {
            idle_mode = false;

            protocol_line_buffer_feed(&line, (const uint8_t *)recv_buffer,
                                      (size_t)bytes_read, handle_protocol_line);

            // Any received data counts as activity, even if it does not
            // complete a line.
            s_last_command_time = xTaskGetTickCount();
        } else {
            uint32_t elapsed = xTaskGetTickCount() - s_last_command_time;

            if (elapsed > pdMS_TO_TICKS(DISCONNECT_TIMEOUT_MS) && !idle_mode) {
                ESP_LOGW(TAG, "No commands for %lu ms - entering idle mode",
                         (unsigned long)(elapsed * portTICK_PERIOD_MS));
                led_blink_slow();
                idle_mode = true;
            }
        }
    }

    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "ObsStatus ESP32 Firmware " FIRMWARE_VERSION);

    // Pin to the second core when available; unicore chips (ESP32-C6)
    // must use core 0 or xTaskCreatePinnedToCore asserts.
    const BaseType_t app_core = (CONFIG_FREERTOS_NUMBER_OF_CORES > 1) ? 1 : 0;

    xTaskCreatePinnedToCore(
        app_task,
        "app_task",
        APP_TASK_STACK_SIZE,
        NULL,
        APP_TASK_PRIORITY,
        NULL,
        app_core
    );
}
