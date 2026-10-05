/**
 * @file imu_qmi8658.c
 * @brief Minimal QMI8658A accelerometer driver (display boards only)
 *
 * Register values follow the vendor BSP init sequence. Only the
 * accelerometer is enabled; that is all the screen auto-rotation needs.
 */

#include "imu_qmi8658.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"

#include "board_i2c.h"

static const char *TAG = "imu";

#define QMI8658_I2C_ADDR    0x6B
#define QMI8658_WHO_AM_I    0x00
#define QMI8658_CTRL1       0x02 /* 0x40: register address auto-increment */
#define QMI8658_CTRL2       0x03 /* 0x95: accel +/-4 g, 250 Hz */
#define QMI8658_CTRL3       0x04 /* 0xD5: gyro +/-512 dps, 250 Hz */
#define QMI8658_CTRL7       0x08 /* 0x03: enable accelerometer + gyroscope */
#define QMI8658_STATUS0     0x2E /* bit 0: accel sample ready */
#define QMI8658_AX_L        0x35 /* AX_L..AZ_H: three little-endian int16 */
#define QMI8658_RESET       0x60

#define QMI8658_WHO_AM_I_ID 0x05
#define ACCEL_G_PER_LSB     (4.0f / 32768.0f)

/* The vendor BSP uses a 1 s timeout on this bus; shorter timeouts make reads
 * fail en masse because the chip stretches the clock occasionally. */
#define QMI8658_I2C_TIMEOUT_MS 1000

static i2c_master_dev_handle_t s_dev = NULL;
static uint8_t s_last_status = 0;
static bool s_last_error = false;

static esp_err_t reg_read(uint8_t reg, uint8_t *data, size_t len)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, data, len,
                                       pdMS_TO_TICKS(QMI8658_I2C_TIMEOUT_MS));
}

static esp_err_t reg_write(uint8_t reg, uint8_t value)
{
    const uint8_t buf[2] = { reg, value };
    return i2c_master_transmit(s_dev, buf, sizeof buf, pdMS_TO_TICKS(QMI8658_I2C_TIMEOUT_MS));
}

esp_err_t imu_init(void)
{
    i2c_master_bus_handle_t bus = board_i2c_bus();
    if (bus == NULL) {
        return ESP_FAIL;
    }

    const i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = QMI8658_I2C_ADDR,
        .scl_speed_hz = 400000, /* same rate as the touch controller on this bus */
    };
    if (i2c_master_bus_add_device(bus, &dev_config, &s_dev) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add IMU to I2C bus");
        s_dev = NULL;
        return ESP_FAIL;
    }

    uint8_t id = 0;
    if (reg_read(QMI8658_WHO_AM_I, &id, 1) != ESP_OK || id != QMI8658_WHO_AM_I_ID) {
        ESP_LOGW(TAG, "QMI8658A not found (WHO_AM_I = 0x%02x)", id);
        i2c_master_bus_rm_device(s_dev);
        s_dev = NULL;
        return ESP_ERR_NOT_FOUND;
    }

    /* Vendor init sequence, verbatim: soft reset, address auto-increment,
     * accel+gyro enabled, accel +/-4 g @ 250 Hz, gyro +/-512 dps @ 250 Hz.
     * (Enabling the accel alone, CTRL7=0x01, leaves this chip reporting
     * zeros, so the full vendor sequence is kept.) */
    if (reg_write(QMI8658_RESET, 0xB0) != ESP_OK) {
        return ESP_FAIL;
    }
    vTaskDelay(pdMS_TO_TICKS(10));
    if (reg_write(QMI8658_CTRL1, 0x40) != ESP_OK ||
        reg_write(QMI8658_CTRL7, 0x03) != ESP_OK ||
        reg_write(QMI8658_CTRL2, 0x95) != ESP_OK ||
        reg_write(QMI8658_CTRL3, 0xD5) != ESP_OK) {
        ESP_LOGE(TAG, "IMU configuration failed");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "QMI8658A initialized");
    return ESP_OK;
}

bool imu_read_accel(float *ax_g, float *ay_g, float *az_g)
{
    if (s_dev == NULL) {
        return false;
    }
    uint8_t status = 0;
    if (reg_read(QMI8658_STATUS0, &status, 1) != ESP_OK) {
        s_last_error = true;
        return false;
    }
    s_last_error = false;
    s_last_status = status;
    if ((status & 0x01) == 0) {
        /* No fresh accelerometer sample yet */
        return false;
    }
    uint8_t raw[6];
    if (reg_read(QMI8658_AX_L, raw, sizeof(raw)) != ESP_OK) {
        s_last_error = true;
        return false;
    }
    const int16_t ax = (int16_t)((uint16_t)raw[0] | ((uint16_t)raw[1] << 8));
    const int16_t ay = (int16_t)((uint16_t)raw[2] | ((uint16_t)raw[3] << 8));
    const int16_t az = (int16_t)((uint16_t)raw[4] | ((uint16_t)raw[5] << 8));
    *ax_g = (float)ax * ACCEL_G_PER_LSB;
    *ay_g = (float)ay * ACCEL_G_PER_LSB;
    *az_g = (float)az * ACCEL_G_PER_LSB;
    return true;
}

void imu_get_diag(uint8_t *status0, bool *bus_error)
{
    if (status0 != NULL) {
        *status0 = s_last_status;
    }
    if (bus_error != NULL) {
        *bus_error = s_last_error;
    }
}
