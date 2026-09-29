/**
 * @file usb_cdc.h
 * @brief USB CDC (Virtual Serial Port) interface for ESP32
 * 
 * Provides USB CDC-ACM communication with macOS application
 * over native USB on ESP32-S3.
 */

#ifndef USB_CDC_H
#define USB_CDC_H

#include <esp_err.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize USB CDC device
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t usb_cdc_init(void);

/**
 * @brief Send data to the connected macOS application
 * @param data Pointer to data buffer
 * @param len Length of data to send
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t usb_cdc_send(const uint8_t *data, size_t len);

/**
 * @brief Receive data from the connected macOS application
 * @param buffer Output buffer
 * @param len Maximum number of bytes to receive
 * @param timeout Wait timeout in ticks (portTICK_PERIOD_MS)
 * @return Number of bytes received, negative on error
 */
int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout);

/**
 * @brief Check if USB CDC link is active (macOS application connected)
 * @return true if connected, false otherwise
 */
bool usb_cdc_is_connected(void);

#ifdef __cplusplus
}
#endif

#endif /* USB_CDC_H */
