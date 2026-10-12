/**
 * @file usb_cdc.h
 * @brief USB CDC interface for ESP32
 */

#ifndef USB_CDC_H
#define USB_CDC_H

#include <esp_err.h>
#include <stdint.h>
#include <stddef.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t usb_cdc_init(void);
/**
 * @brief Blocking write of a whole frame (command responses)
 *
 * The entire call is serialized with other protocol writers (app task,
 * touch task) by an internal TX lock, so one response cannot be
 * interleaved with another protocol write. Can still return ESP_FAIL if
 * the host stops draining (host asleep); the host then times out and
 * retries the command.
 */
esp_err_t usb_cdc_send(const uint8_t *data, size_t len);
/**
 * @brief Non-blocking variant of usb_cdc_send
 *
 * Fails immediately (ESP_ERR_TIMEOUT) when the USB host is not draining
 * instead of blocking; meant for unsolicited events such as
 * EVENT:TOGGLE_PAUSE, where a lost frame is acceptable.
 */
esp_err_t usb_cdc_send_nowait(const uint8_t *data, size_t len);
int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout);
bool usb_cdc_is_connected(void);

#ifdef __cplusplus
}
#endif

#endif /* USB_CDC_H */
