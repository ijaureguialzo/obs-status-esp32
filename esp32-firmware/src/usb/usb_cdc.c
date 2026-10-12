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

/* Guards the driver calls: on chips where the USB Serial JTAG install
 * fails (or before init), the raw driver functions must not be touched. */
static bool s_installed = false;

/* Serializes our protocol writes (app task answering commands, touch task
 * emitting events) with each other, so a multi-chunk usb_cdc_send() cannot
 * be interleaved with another protocol write.
 *
 * Note on the driver internals (esp_driver_usb_serial_jtag, IDF 5.x):
 * usb_serial_jtag_write_bytes() holds the driver's internal tx mutex for
 * the whole call, so a single response (one call) always lands contiguous
 * in the TX FIFO. The console (ESP_LOG) uses the VFS, which writes one
 * character per driver call, so log lines can be split by protocol writes
 * (cosmetic: the host drops unparseable lines), but a protocol response
 * written in one usb_cdc_send() is never split by another *protocol* write
 * as long as both go through s_tx_lock. A response whose send fails midway
 * (host not draining, TX ring full) can still be truncated; the host
 * treats that as a timeout and retries. */
static SemaphoreHandle_t s_tx_lock = NULL;

esp_err_t usb_cdc_init(void)
{
    ESP_LOGI(TAG, "Initializing USB Serial JTAG");

    usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    esp_err_t ret = usb_serial_jtag_driver_install(&config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to install USB JTAG driver: %s", esp_err_to_name(ret));
        return ret;
    }

    s_tx_lock = xSemaphoreCreateMutex();
    if (s_tx_lock == NULL) {
        ESP_LOGW(TAG, "Could not create the TX lock; protocol writes are no longer serialized");
    }

    s_installed = true;
    ESP_LOGI(TAG, "USB Serial JTAG initialized");
    return ESP_OK;
}

esp_err_t usb_cdc_send(const uint8_t *data, size_t len)
{
    if (!s_installed || data == NULL || len == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    /* Keep the whole response together (see the s_tx_lock note above). The
     * lock is a FastMutex-free mutex; all callers are tasks, so blocking on
     * it is fine. */
    if (s_tx_lock != NULL && xSemaphoreTake(s_tx_lock, portMAX_DELAY) != pdTRUE) {
        return ESP_FAIL;
    }

    esp_err_t result = ESP_OK;
    size_t total_written = 0;
    while (total_written < len) {
        int written = usb_serial_jtag_write_bytes(data + total_written,
                                                  len - total_written,
                                                  pdMS_TO_TICKS(1000));
        if (written <= 0) {
            result = ESP_FAIL;
            break;
        }
        total_written += (size_t)written;
    }

    if (s_tx_lock != NULL) {
        xSemaphoreGive(s_tx_lock);
    }
    return result;
}

esp_err_t usb_cdc_send_nowait(const uint8_t *data, size_t len)
{
    if (!s_installed || data == NULL || len == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    /* Zero timeout: fails fast when the host is not draining (e.g. the Mac
     * is asleep). Only for unsolicited events where a lost frame is
     * acceptable; use usb_cdc_send() for command responses. Shares the TX
     * lock with usb_cdc_send() so an event cannot land inside a response. */
    if (s_tx_lock != NULL && xSemaphoreTake(s_tx_lock, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t result;
    if (usb_serial_jtag_write_bytes(data, len, 0) != (int)len) {
        result = ESP_ERR_TIMEOUT;
    } else {
        result = ESP_OK;
    }
    if (s_tx_lock != NULL) {
        xSemaphoreGive(s_tx_lock);
    }
    return result;
}

int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout)
{
    if (!s_installed || buffer == NULL) {
        return 0;
    }
    return usb_serial_jtag_read_bytes(buffer, len, timeout);
}

bool usb_cdc_is_connected(void)
{
    return s_installed && usb_serial_jtag_is_connected();
}
