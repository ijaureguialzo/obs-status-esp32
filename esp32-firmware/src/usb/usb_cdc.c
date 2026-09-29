/**
 * @file usb_cdc.c
 * @brief USB CDC device driver wrapper for ESP32-S3
 * 
 * Implements USB CDC-ACM communication using ESP-IDF's native USB stack.
 * Creates a virtual serial port that the macOS application can communicate with.
 */

#include "usb_cdc.h"
#include "usb/usb_device.h"
#include "usb/usb_serial_jtag.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

// Configuration
#define USB_CDC_BUF_SIZE 256
#define USB_CDC_TASK_STACK_SIZE 1024
#define USB_CDC_TASK_PRIORITY 5

// Internal state
static bool s_connected = false;
static uint8_t s_buffer[USB_CDC_BUF_SIZE];
static size_t s_bytes_in_buffer = 0;

esp_err_t usb_cdc_init(void)
{
    esp_err_t ret;
    
    // Initialize USB device
    ret = usb_device_init();
    if (ret != ESP_OK) {
        return ret;
    }
    
    // Initialize USB Serial JTAG interface (alternative to CDC for ESP32-S3)
    // For ESP32-S3, we can use the USB JTAG interface or the USB CDC stack
    
    s_connected = false;
    s_bytes_in_buffer = 0;
    
    return ESP_OK;
}

esp_err_t usb_cdc_send(const uint8_t *data, size_t len)
{
    if (!s_connected) {
        return ESP_ERR_NOT_CONNECTED;
    }
    
    // Use USB JTAG TX endpoint for sending data
    size_t written = 0;
    esp_err_t ret = usb_serial_jtag_write(data, len, &written);
    
    if (ret != ESP_OK) {
        return ret;
    }
    
    return ESP_OK;
}

int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout)
{
    if (!s_connected) {
        return -1;
    }
    
    // Use USB JTAG RX endpoint for receiving data
    int bytes_read = usb_serial_jtag_read(buffer, len, timeout);
    
    return bytes_read;
}

bool usb_cdc_is_connected(void)
{
    return s_connected;
}

// TODO: Implement USB CDC connection event handling
// For ESP32-S3 native USB, use usb_device_register_callbacks() 
// to monitor connection/disconnection events.
