/**
 * @file touch_controller.c
 * @brief AXS5106L touch input for the Waveshare ESP32-C6-Touch-LCD-1.47
 *
 * Polls the touch controller over I2C and, on every tap (rising edge),
 * sends the EVENT:TOGGLE_PAUSE line over USB CDC so the host can
 * pause/resume the OBS recording.
 *
 * Compiled out unless CONFIG_BOARD_HAS_DISPLAY is defined.
 */

#include "touch_controller.h"

#if CONFIG_BOARD_HAS_DISPLAY

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_check.h"
#include "driver/i2c_master.h"
#include "esp_lcd_touch.h"
#include "esp_lcd_touch_axs5106.h"

#include "protocol_parser.h"

static const char *TAG = "touch";

/* Waveshare ESP32-C6-Touch-LCD-1.47 pinout (see vendor BSP) */
#define TOUCH_PIN_I2C_SDA 18
#define TOUCH_PIN_I2C_SCL 19
#define TOUCH_PIN_RST     20
#define TOUCH_PIN_INT     21

#define TOUCH_I2C_PORT       0
#define TOUCH_I2C_CLOCK_HZ   400000
#define TOUCH_X_MAX          172
#define TOUCH_Y_MAX          320
#define TOUCH_POLL_MS        50
#define TOUCH_TASK_STACK     3072
#define TOUCH_TASK_PRIORITY  5

static void touch_task(void *pv_parameters)
{
    esp_lcd_touch_handle_t touch = (esp_lcd_touch_handle_t)pv_parameters;
    bool was_pressed = false;

    while (1) {
        if (esp_lcd_touch_read_data(touch) == ESP_OK) {
            esp_lcd_touch_point_data_t point;
            uint8_t count = 0;

            esp_lcd_touch_get_data(touch, &point, &count, 1);
            bool pressed = count > 0;
            if (pressed && !was_pressed) {
                ESP_LOGI(TAG, "Tap detected - toggling record pause");
                protocol_notify_toggle_pause();
            }
            was_pressed = pressed;
        }
        vTaskDelay(pdMS_TO_TICKS(TOUCH_POLL_MS));
    }
}

esp_err_t touch_init(void)
{
    i2c_master_bus_handle_t bus_handle = NULL;
    const i2c_master_bus_config_t bus_config = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = TOUCH_I2C_PORT,
        .scl_io_num = TOUCH_PIN_I2C_SCL,
        .sda_io_num = TOUCH_PIN_I2C_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = 1,
    };
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_config, &bus_handle),
                        TAG, "I2C bus init failed");

    i2c_master_dev_handle_t dev_handle = NULL;
    const i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ESP_LCD_TOUCH_IO_I2C_AXS5106_ADDRESS,
        .scl_speed_hz = TOUCH_I2C_CLOCK_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(bus_handle, &dev_config, &dev_handle),
                        TAG, "I2C device add failed");

    esp_lcd_touch_handle_t touch = NULL;
    esp_lcd_touch_config_t touch_config = {
        .x_max = TOUCH_X_MAX,
        .y_max = TOUCH_Y_MAX,
        .rst_gpio_num = TOUCH_PIN_RST,
        .int_gpio_num = TOUCH_PIN_INT,
        /* Same transform as the vendor BSP uses for 0 degree rotation */
        .flags.swap_xy = 0,
        .flags.mirror_x = 1,
        .flags.mirror_y = 0,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_touch_new_i2c_axs5106(dev_handle, &touch_config, &touch),
                        TAG, "AXS5106 init failed");

    if (xTaskCreate(touch_task, "touch", TOUCH_TASK_STACK, touch,
                    TOUCH_TASK_PRIORITY, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Touch initialized");
    return ESP_OK;
}

#else /* !CONFIG_BOARD_HAS_DISPLAY */

esp_err_t touch_init(void)
{
    return ESP_OK;
}

#endif /* CONFIG_BOARD_HAS_DISPLAY */
