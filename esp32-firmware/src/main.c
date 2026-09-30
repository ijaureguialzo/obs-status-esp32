/**
 * @file app_main.c
 * @brief Main application entry point for ObsStatus ESP32 firmware
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"

#include "usb_cdc.h"
#include "led_controller.h"
#include "protocol_parser.h"
#include "obs_protocol.h"

static const char *TAG = "obs-status";

#define APP_TASK_STACK_SIZE 2048
#define APP_TASK_PRIORITY 5
#define USB_RECV_TIMEOUT_MS 100
#define DISCONNECT_TIMEOUT_MS 10000

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

    ESP_LOGI(TAG, "Initializing LED on GPIO%d", CONFIG_LED_GPIO_NUM);
    ret = led_init(CONFIG_LED_GPIO_NUM);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize LED: %s", esp_err_to_name(ret));
    }

    ret = protocol_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize protocol parser");
    }

    led_blink_slow();

    char recv_buffer[PROTOCOL_MAX_LINE_LENGTH];
    char line_buffer[PROTOCOL_MAX_LINE_LENGTH];
    size_t line_length = 0;
    uint32_t last_command_time = 0;

    ESP_LOGI(TAG, "Entering main loop (waiting for commands)");

    while (1) {
        int bytes_read = usb_cdc_recv((uint8_t *)recv_buffer,
                                       sizeof(recv_buffer) - 1,
                                       pdMS_TO_TICKS(USB_RECV_TIMEOUT_MS));

        if (bytes_read > 0) {
            recv_buffer[bytes_read] = '\0';

            for (int i = 0; i < bytes_read; i++) {
                if (recv_buffer[i] == '\n') {
                    if (line_length > 0) {
                        line_buffer[line_length] = '\0';
                        ESP_LOGI(TAG, "Received command: %s", line_buffer);

                        protocol_process(line_buffer);

                        line_length = 0;
                        last_command_time = xTaskGetTickCount();
                    }
                } else if (recv_buffer[i] != '\r') {
                    if (line_length < PROTOCOL_MAX_LINE_LENGTH - 1) {
                        line_buffer[line_length++] = recv_buffer[i];
                    }
                }
            }

            last_command_time = xTaskGetTickCount();
        } else {
            uint32_t elapsed = xTaskGetTickCount() - last_command_time;

            if (elapsed > pdMS_TO_TICKS(DISCONNECT_TIMEOUT_MS)) {
                ESP_LOGW(TAG, "No commands for %lu ms - entering idle mode",
                         (unsigned long)(elapsed * portTICK_PERIOD_MS));
                led_blink_slow();
            }
        }
    }

    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "ObsStatus ESP32 Firmware v1.0.0");

    xTaskCreatePinnedToCore(
        app_task,
        "app_task",
        APP_TASK_STACK_SIZE,
        NULL,
        APP_TASK_PRIORITY,
        NULL,
        1
    );
}
