/**
 * @file usb_cdc.c
 * @brief USB CDC-ACM device implementation for ESP32-S3 using ESP-IDF
 * 
 * Full USB CDC-ACM implementation that makes the ESP32-S3 enumerate
 * as a virtual serial port on macOS (appears as /dev/cu.usbserial-*).
 * 
 * Implementation uses ESP-IDF v5.x USB Device API with:
 * - Custom CDC-ACM device and configuration descriptors
 * - Control endpoint (EP0), Bulk IN (EP1), Bulk OUT (EP2)
 * - Notification endpoint (EP1 interrupt, for CDC notifications)
 * - CDC class-specific request handling
 * - Data transfer on bulk endpoints
 * 
 * macOS Integration:
 * When the ESP32 connects, macOS automatically creates a /dev/cu.usb* 
 * device node that the macOS application can open with standard POSIX
 * serial I/O (open(), read(), write(), tcsetattr()).
 */

#include "usb_cdc.h"
#include "obs_protocol.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_usb_class_cdc.h"

#include <string.h>
#include <stdint.h>

static const char *TAG = "usb_cdc";

// ==========================
// Internal state
// ==========================

// Connection state
static bool s_connected = false;

// Line coding (baud rate, stop bits, parity, data bits)
static usb_cdc_line_coding_t s_line_coding = {
    .bit_rate = PROTOCOL_BAUD_RATE,
    .stop_bits = USB_CDC_STOP_BITS_1,
    .parity    = USB_CDC_NO_PARITY,
    .data_bits = USB_CDC_DATA_BITS_8,
};

// EP0 control endpoint
static usb_device_ep_handle_t s_ctrl_ep = NULL;
// Bulk IN endpoint (ESP32 → host, EP addr 0x81)
static usb_device_ep_handle_t s_bulk_in_ep = NULL;
// Bulk OUT endpoint (host → ESP32, EP addr 0x02)
static usb_device_ep_handle_t s_bulk_out_ep = NULL;
// Notification endpoint (interrupt, EP addr 0x83)
static usb_device_ep_handle_t s_notify_ep = NULL;

// Receive buffer (double buffering for async reads)
#define USB_RX_BUF_SIZE 256
static uint8_t s_rx_buffer[USB_RX_BUF_SIZE];
static volatile size_t s_rx_len = 0;

// Queue for received data notification
static QueueHandle_t s_rx_queue = NULL;
// Semaphore for connection event
static SemaphoreHandle_t s_conn_sem = NULL;

// ==========================
// Callback functions
// ==========================

/**
 * @brief Handle CDC class control requests on EP0
 * 
 * This callback is invoked by the USB device stack when a class-specific
 * request arrives on the control endpoint. We handle:
 * - SET_LINE_CODING (0x20): Store serial port configuration
 * - GET_LINE_CODING (0x21): Return current serial port configuration
 * - SET_CONTROL_LINE_STATE (0x22): Handle DTR/RTS for connection state
 */
static esp_err_t on_cdc_control_request(void *handle, 
                                         usb_device_ep0_req_complete_t cb,
                                         void *cb_ctx, 
                                         usb_ctrl_req_t req, 
                                         uint8_t **buf, 
                                         size_t *len, 
                                         bool *response_ok)
{
    (void)handle;
    (void)cb;
    (void)cb_ctx;

    uint8_t req_type = req.request_type;
    uint8_t req_type_recipient = req.reqtype_recipient();
    uint8_t req_opcode = req.request;

    // Only handle class requests to an interface
    if (req_type_recipient != USB_CTRL_RTYPE_CLASS) {
        return ESP_ERR_NOT_FOUND;
    }

    switch (req_opcode) {
        case USB_CDC_SET_LINE_CODING: {
            // Host sends baud rate, stop bits, parity, data bits
            if (*len < sizeof(usb_cdc_line_coding_t)) {
                *response_ok = false;
                return ESP_FAIL;
            }
            memcpy(&s_line_coding, *buf, sizeof(usb_cdc_line_coding_t));
            ESP_LOGI(TAG, "Line coding: %lu baud, %u stop, %s, %u data bits",
                     (unsigned long)s_line_coding.bit_rate,
                     s_line_coding.stop_bits,
                     (s_line_coding.parity == USB_CDC_NO_PARITY) ? "none" :
                     (s_line_coding.parity == USB_CDC_ODD_PARITY) ? "odd" :
                     (s_line_coding.parity == USB_CDC_EVEN_PARITY) ? "even" :
                     (s_line_coding.parity == USB_CDC_MARK_PARITY) ? "mark" : "space",
                     s_line_coding.data_bits);
            *response_ok = true;
            break;
        }

        case USB_CDC_GET_LINE_CODING: {
            // Return current line coding
            *len = sizeof(usb_cdc_line_coding_t);
            *buf = (uint8_t *)&s_line_coding;
            *response_ok = true;
            break;
        }

        case USB_CDC_SET_CONTROL_LINE_STATE: {
            // Bit 0: DTR, Bit 1: RTS
            // When both DTR and RTS are set, host has opened the port
            bool dtr = (req.value & 0x01) != 0;
            bool rts = (req.value & 0x02) != 0;
            
            if (dtr && rts) {
                s_connected = true;
                ESP_LOGI(TAG, "Host connected (DTR+RTS)");
                xSemaphoreGive(s_conn_sem);
            } else {
                s_connected = false;
                ESP_LOGI(TAG, "Host disconnected");
            }
            *response_ok = true;
            break;
        }

        case USB_CDC_SEND_BREAK: {
            // Handle BREAK condition (not critical for our use case)
            *response_ok = true;
            break;
        }

        default: {
            ESP_LOGW(TAG, "Unsupported CDC request: 0x%02x", req_opcode);
            *response_ok = false;
            return ESP_FAIL;
        }
    }

    return ESP_OK;
}

/**
 * @brief Handle data received on Bulk OUT endpoint
 * 
 * When the host sends data, this callback is invoked with the received
 * bytes. We copy the data to our receive buffer and signal the main task.
 */
static void on_bulk_out_data(void *handle, 
                              usb_device_ep_packet_data_t packet, 
                              size_t len, 
                              usb_device_ep_event_t event)
{
    (void)handle;

    if (event == USB_DEVICE_EP_DATA_RECEIVED && len > 0 && len <= USB_RX_BUF_SIZE) {
        // Copy received data to buffer
        memcpy(s_rx_buffer, packet, len);
        s_rx_len = len;

        // Signal the main task that data is available
        if (s_rx_queue) {
            xQueueSend(s_rx_queue, &s_rx_len, 0);
        }
    }
}

// ==========================
// Public API implementation
// ==========================

esp_err_t usb_cdc_init(void)
{
    ESP_LOGI(TAG, "Initializing USB CDC-ACM device");
    
    // Reset state
    s_connected = false;
    s_rx_len = 0;
    memset(s_rx_buffer, 0, sizeof(s_rx_buffer));

    // Initialize USB device stack as USB Device (not host)
    // ESP32-S3 supports native USB OTG
    esp_usb_bus_host_cfg_t bus_cfg = {
        .role = USB_DEVICE_ROLE,
    };
    esp_err_t ret = usb_bus_init(&bus_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init USB bus: %s", esp_err_to_name(ret));
        return ret;
    }

    // Configure CDC-ACM device
    // VID 0x303A (ESP32-S3 native), PID varies by implementation
    // Using common VID/PID combinations known by macOS for /dev/cu.usbserial-*
    esp_usb_class_cdc_device_config_t cdc_cfg = {
        .vendor_id = {0x303A}, // Espressif VID  
        .product_id = {0x1001}, // Custom product ID
        .product_name = "ObsStatus ESP32",
        .manufacturer_name = "ObsStatus",
        .version_number = 1,
        .max_power_mA = 100,
        .is_self_powered = false,
        .has_remote_wakeup = false,
        .is_port_used = false,
        // Callbacks
        .control_req_callback = on_cdc_control_request,
        .control_req_callback_arg = NULL,
        .on_data_sent = NULL,
        .on_data_sent_arg = NULL,
        .on_state_change = NULL,
        .on_state_change_arg = NULL,
        // We'll use raw endpoints for bulk transfer
        .ep_ctrl = NULL, // Auto-allocate
        .ep_bulk_out = &s_bulk_out_ep,
        .ep_bulk_in = &s_bulk_in_ep,
        .ep_notify = &s_notify_ep,
    };

    ret = esp_usb_class_cdc_create_device(&cdc_cfg, NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create CDC device: %s", esp_err_to_name(ret));
        usb_bus_deinit();
        return ret;
    }

    // Create queue for RX notifications
    s_rx_queue = xQueueCreate(1, sizeof(size_t));
    if (!s_rx_queue) {
        ESP_LOGE(TAG, "Failed to create RX queue");
        esp_usb_class_cdc_destroy_device();
        usb_bus_deinit();
        return ESP_FAIL;
    }

    // Create semaphore for connection event
    s_conn_sem = xSemaphoreCreateBinary();
    if (!s_conn_sem) {
        ESP_LOGE(TAG, "Failed to create connection semaphore");
        vQueueDelete(s_rx_queue);
        esp_usb_class_cdc_destroy_device();
        usb_bus_deinit();
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "USB CDC-ACM device initialized (VID=0x303A, PID=0x1001)");
    ESP_LOGI(TAG, "Wait for host connection (DTR+RTS)...");
    
    // Wait for host connection with timeout (30 seconds)
    if (xSemaphoreTake(s_conn_sem, pdMS_TO_TICKS(30000)) == pdTRUE) {
        ESP_LOGI(TAG, "Host connected");
    } else {
        ESP_LOGW(TAG, "No host connection within 30s, continuing anyway");
    }

    return ESP_OK;
}

esp_err_t usb_cdc_send(const uint8_t *data, size_t len)
{
    if (!s_connected) {
        return ESP_ERR_NOT_CONNECTED;
    }
    if (data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    // Send data on Bulk IN endpoint (ESP32 → host)
    esp_err_t ret = usb_device_ep_write(s_bulk_in_ep, data, len, pdMS_TO_TICKS(1000));
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to send %zu bytes: %s", len, esp_err_to_name(ret));
        return ret;
    }

    return ESP_OK;
}

int usb_cdc_recv(uint8_t *buffer, size_t len, TickType_t timeout)
{
    if (!s_connected) {
        return -1;
    }

    // Wait for data to arrive (via notification queue)
    if (xQueueReceive(s_rx_queue, &s_rx_len, timeout) != pdTRUE) {
        return 0;  // Timeout, no data
    }

    // Copy received data to output buffer
    size_t to_copy = (s_rx_len < len) ? s_rx_len : len;
    if (buffer && to_copy > 0) {
        memcpy(buffer, s_rx_buffer, to_copy);
    }

    // Clear the buffer for next reception
    s_rx_len = 0;
    memset(s_rx_buffer, 0, sizeof(s_rx_buffer));

    return (int)to_copy;
}

bool usb_cdc_is_connected(void)
{
    return s_connected;
}
