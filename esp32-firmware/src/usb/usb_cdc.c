/**
 * @file usb_cdc.c
 * @brief USB Serial JTAG implementation for ESP32-S3 using ESP-IDF
 * 
 * Uses the simple blocking API of the USB Serial JTAG driver:
 * - usb_serial_jtag_driver_install() - Install driver
 * - usb_serial_jtag_read_bytes() - Blocking read
 * - usb_serial_jtag_write_bytes() - Blocking write  
 * - usb_serial_jtag_is_connected() - Check connection
 */

#include "usb_cdc.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "driver/usb_serial_jtag.h"

#include <string.h>
#include <stdint.h>

static const char *TAG = "usb_serial";

esp_err_t usb_cdc_init(void)
{
    ESP_LOGI(TAG, "Initializing USB Serial JTAG");

    usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    esp_err_t ret = usb_serial_jtag_driver_install(&config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to install USB JTAG driver: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "USB Serial JTAG initialized");
    return ESP_OK;
}

esp_err_t usb_cdc_send(const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    int written = usb_serial_jtag_write_bytes(data, len, pdMS_TO_TICKS(1000));
    return (written >= 0) ? ESP_OK : ESP_FAIL;
}

int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout)
{
    return usb_serial_jtag_read_bytes(buffer, len, timeout);
}

bool usb_cdc_is_connected(void)
{
    return usb_serial_jtag_is_connected();
}
