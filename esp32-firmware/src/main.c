/**
 * @file app_main.c
 * @brief Main application entry point for ObsStatus ESP32 firmware
 * 
 * Initializes USB CDC and LED controller, then enters the main loop:
 * 1. Read from USB CDC (blocking, 100ms timeout)
 * 2. If data received: buffer into line, parse and dispatch on '\n'
 * 3. If no data for 10 seconds: BLINK_SLOW (disconnected)
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_sleep.h"
#include "nvs_flash.h"

#include "usb_cdc.h"
#include "led_controller.h"
#include "protocol_parser.h"
#include "obs_protocol.h"

static const char *TAG = "obs-status";

#define APP_TASK_STACK_SIZE 2048
#define APP_TASK_PRIORITY 5
#define USB_RECV_TIMEOUT_MS 100
#define DISCONNECT_TIMEOUT_MS 10000  // 10 seconds without commands

static void app_task(void *pv_parameters)
{
    ESP_LOGI(TAG, "ObsStatus firmware starting");
    
    // Step 1: Initialize NVS (if needed for future config storage)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_VERSION_MISMATCH) {
        ESP_LOGW(TAG, "NVS partition issue, erasing and retrying");
        nvs_flash_erase();
        nvs_flash_init();
    }
    
    // Step 2: Initialize USB CDC
    ESP_LOGI(TAG, "Initializing USB CDC");
    ret = usb_cdc_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize USB CDC: %s", esp_err_to_name(ret));
        // Continue anyway - try USB JTAG as fallback
    }
    
    // Step 3: Initialize LED (default: BLINK_SLOW)
    ESP_LOGI(TAG, "Initializing LED on GPIO%d", CONFIG_LED_GPIO_NUM);
    ret = led_init(CONFIG_LED_GPIO_NUM);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize LED: %s", esp_err_to_name(ret));
        // Continue anyway - no LED is better than no response
    }
    
    // Step 4: Initialize protocol parser
    ret = protocol_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize protocol parser");
    }
    
    // Start with slow blink (waiting for commands)
    led_blink_slow();
    
    char recv_buffer[PROTOCOL_MAX_LINE_LENGTH];
    char line_buffer[PROTOCOL_MAX_LINE_LENGTH];
    size_t line_length = 0;
    uint32_t last_command_time = 0;
    
    ESP_LOGI(TAG, "Entering main loop (waiting for commands)");
    
    // Main loop
    while (1) {
        // Read from USB CDC with timeout
        int bytes_read = usb_cdc_recv((uint8_t *)recv_buffer, 
                                       sizeof(recv_buffer) - 1, 
                                       pdMS_TO_TICKS(USB_RECV_TIMEOUT_MS));
        
        if (bytes_read > 0) {
            recv_buffer[bytes_read] = '\0';
            
            // Process each character
            for (int i = 0; i < bytes_read; i++) {
                if (recv_buffer[i] == '\n') {
                    // End of command - process it
                    if (line_length > 0) {
                        line_buffer[line_length] = '\0';
                        ESP_LOGI(TAG, "Received command: %s", line_buffer);
                        
                        protocol_process(line_buffer);
                        
                        // Reset tracking
                        line_length = 0;
                        last_command_time = xTaskGetTickCount();
                    }
                } else if (recv_buffer[i] != '\r') {
                    // Accumulate in line buffer (skip \r)
                    if (line_length < PROTOCOL_MAX_LINE_LENGTH - 1) {
                        line_buffer[line_length++] = recv_buffer[i];
                    }
                }
            }
            
            // Reset disconnect timer on any received data
            last_command_time = xTaskGetTickCount();
        } else {
            // Check for disconnect timeout
            uint32_t elapsed = xTaskGetTickCount() - last_command_time;
            
            if (elapsed > pdMS_TO_TICKS(DISCONNECT_TIMEOUT_MS)) {
                ESP_LOGW(TAG, "No commands for %lu ms - entering idle mode", 
                         (unsigned long)(elapsed * portTICK_PERIOD_MS));
                led_blink_slow();
            }
        }
    }
    
    vTaskNeverDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "ObsStatus ESP32 Firmware v1.0.0");
    ESP_LOGI(TAG, "Target: %s", CONFIG_IDF_TARGET);
    ESP_LOGI(TAG, "LED GPIO: %d", CONFIG_LED_GPIO_NUM);
    
    // Start application task
    xTaskCreatePinnedToCore(
        app_task,
        "app_task",
        APP_TASK_STACK_SIZE,
        NULL,
        APP_TASK_PRIORITY,
        NULL,
        1  // Run on core 1
    );
}
