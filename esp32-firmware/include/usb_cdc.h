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
esp_err_t usb_cdc_send(const uint8_t *data, size_t len);
int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout);
bool usb_cdc_is_connected(void);

#ifdef __cplusplus
}
#endif

#endif /* USB_CDC_H */
