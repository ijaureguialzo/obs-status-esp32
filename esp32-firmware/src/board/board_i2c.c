/**
 * @file board_i2c.c
 * @brief Shared onboard I2C bus (Waveshare ESP32-C6-Touch-LCD-1.47)
 *
 * The AXS5106L touch controller and the QMI8658A IMU share the same bus on
 * GPIO18 (SDA) / GPIO19 (SCL).
 */

#include "board_i2c.h"

#include "esp_log.h"

static const char *TAG = "board_i2c";

#define BOARD_I2C_PORT    0
#define BOARD_PIN_I2C_SDA 18
#define BOARD_PIN_I2C_SCL 19

static i2c_master_bus_handle_t s_bus = NULL;

i2c_master_bus_handle_t board_i2c_bus(void)
{
    if (s_bus != NULL) {
        return s_bus;
    }

    const i2c_master_bus_config_t bus_config = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = BOARD_I2C_PORT,
        .scl_io_num = BOARD_PIN_I2C_SCL,
        .sda_io_num = BOARD_PIN_I2C_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = 1,
    };
    if (i2c_new_master_bus(&bus_config, &s_bus) != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus init failed");
        s_bus = NULL;
        return NULL;
    }
    return s_bus;
}
