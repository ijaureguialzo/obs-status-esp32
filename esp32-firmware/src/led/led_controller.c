/**
 * @file led_controller.c
 * @brief Onboard LED control implementation for ESP32
 */

#include "led_controller.h"
#include "driver/rmt_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/timers.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include <string.h>

#ifndef CONFIG_LED_GPIO_NUM
#define CONFIG_LED_GPIO_NUM 48
#endif

#define LED_RMT_RESOLUTION_HZ 10000000
#define LED_BLINK_FAST_MS 100
#define LED_BLINK_SLOW_MS 500
#define LED_COLOR_LEVEL 32

static const char *TAG = "led";

typedef enum {
    LED_MODE_OFF,
    LED_MODE_ON,
    LED_MODE_BLINK_FAST,
    LED_MODE_BLINK_SLOW,
} led_mode_t;

static uint8_t s_led_pin = CONFIG_LED_GPIO_NUM;
static TimerHandle_t s_blink_timer = NULL;
static SemaphoreHandle_t s_led_mutex = NULL;
static rmt_channel_handle_t s_led_channel = NULL;
static rmt_encoder_handle_t s_led_encoder = NULL;
static led_mode_t s_current_mode = LED_MODE_OFF;
static bool s_led_is_on = false;

static void blink_timer_callback(TimerHandle_t xTimer);
static esp_err_t transmit_color(uint8_t red, uint8_t green, uint8_t blue);

esp_err_t led_init(uint8_t pin)
{
    s_led_pin = pin;
    s_led_mutex = xSemaphoreCreateMutex();
    if (s_led_mutex == NULL) {
        return ESP_ERR_NO_MEM;
    }

    const rmt_tx_channel_config_t channel_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .gpio_num = s_led_pin,
        .mem_block_symbols = 64,
        .resolution_hz = LED_RMT_RESOLUTION_HZ,
        .trans_queue_depth = 1,
    };

    esp_err_t ret = rmt_new_tx_channel(&channel_config, &s_led_channel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create RMT channel on GPIO%d: %s", s_led_pin, esp_err_to_name(ret));
        return ret;
    }

    const rmt_bytes_encoder_config_t encoder_config = {
        .bit0 = {
            .level0 = 1,
            .duration0 = 3,
            .level1 = 0,
            .duration1 = 9,
        },
        .bit1 = {
            .level0 = 1,
            .duration0 = 9,
            .level1 = 0,
            .duration1 = 3,
        },
        .flags.msb_first = 1,
    };

    ret = rmt_new_bytes_encoder(&encoder_config, &s_led_encoder);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create WS2812 encoder: %s", esp_err_to_name(ret));
        rmt_del_channel(s_led_channel);
        s_led_channel = NULL;
        return ret;
    }

    ret = rmt_enable(s_led_channel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to enable RMT channel: %s", esp_err_to_name(ret));
        rmt_del_encoder(s_led_encoder);
        rmt_del_channel(s_led_channel);
        s_led_encoder = NULL;
        s_led_channel = NULL;
        return ret;
    }

    ret = transmit_color(0, 0, 0);
    if (ret != ESP_OK) {
        return ret;
    }

    s_blink_timer = xTimerCreate(
        "led_blink",
        pdMS_TO_TICKS(LED_BLINK_FAST_MS),
        pdTRUE,
        0,
        blink_timer_callback
    );

    if (s_blink_timer == NULL) {
        return ESP_FAIL;
    }

    s_current_mode = LED_MODE_OFF;
    return ESP_OK;
}

void led_on(void)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_current_mode = LED_MODE_ON;
    s_led_is_on = true;
    transmit_color(0, LED_COLOR_LEVEL, 0);
    xSemaphoreGive(s_led_mutex);
    if (s_blink_timer != NULL) {
        xTimerStop(s_blink_timer, 0);
    }
}

void led_off(void)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_current_mode = LED_MODE_OFF;
    s_led_is_on = false;
    transmit_color(0, 0, 0);
    xSemaphoreGive(s_led_mutex);
    if (s_blink_timer != NULL) {
        xTimerStop(s_blink_timer, 0);
    }
}

void led_blink_fast(void)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_current_mode = LED_MODE_BLINK_FAST;
    s_led_is_on = false;
    transmit_color(0, 0, 0);
    xSemaphoreGive(s_led_mutex);
    if (s_blink_timer != NULL) {
        xTimerChangePeriod(s_blink_timer, pdMS_TO_TICKS(LED_BLINK_FAST_MS), 0);
        xTimerStart(s_blink_timer, 0);
    }
}

void led_blink_slow(void)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_current_mode = LED_MODE_BLINK_SLOW;
    s_led_is_on = false;
    transmit_color(0, 0, 0);
    xSemaphoreGive(s_led_mutex);
    if (s_blink_timer != NULL) {
        xTimerChangePeriod(s_blink_timer, pdMS_TO_TICKS(LED_BLINK_SLOW_MS), 0);
        xTimerStart(s_blink_timer, 0);
    }
}

void led_set_pwm(uint8_t brightness)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_current_mode = brightness == 0 ? LED_MODE_OFF : LED_MODE_ON;
    s_led_is_on = brightness != 0;
    transmit_color(0, brightness, 0);
    xSemaphoreGive(s_led_mutex);
    if (s_blink_timer != NULL) {
        xTimerStop(s_blink_timer, 0);
    }
}

void led_set_pattern(const char *pattern)
{
    if (pattern == NULL) {
        led_off();
        return;
    }
    if (strcmp(pattern, "ON") == 0) {
        led_on();
    } else if (strcmp(pattern, "OFF") == 0) {
        led_off();
    } else if (strcmp(pattern, "BLINK_FAST") == 0) {
        led_blink_fast();
    } else if (strcmp(pattern, "BLINK_SLOW") == 0) {
        led_blink_slow();
    } else {
        led_off();
    }
}

static void blink_timer_callback(TimerHandle_t xTimer)
{
    (void)xTimer;
    if (xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    if (s_current_mode == LED_MODE_BLINK_FAST || s_current_mode == LED_MODE_BLINK_SLOW) {
        s_led_is_on = !s_led_is_on;
        transmit_color(0, s_led_is_on ? LED_COLOR_LEVEL : 0, 0);
    }
    xSemaphoreGive(s_led_mutex);
}

bool led_is_on(void)
{
    if (s_led_mutex == NULL || xSemaphoreTake(s_led_mutex, portMAX_DELAY) != pdTRUE) {
        return false;
    }
    const bool is_on = s_led_is_on;
    xSemaphoreGive(s_led_mutex);
    return is_on;
}

static esp_err_t transmit_color(uint8_t red, uint8_t green, uint8_t blue)
{
    if (s_led_channel == NULL || s_led_encoder == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint8_t grb[] = { green, red, blue };
    const rmt_transmit_config_t tx_config = {
        .loop_count = 0,
    };
    esp_err_t ret = rmt_transmit(s_led_channel, s_led_encoder, grb, sizeof(grb), &tx_config);
    if (ret == ESP_OK) {
        ret = rmt_tx_wait_all_done(s_led_channel, pdMS_TO_TICKS(10));
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to update RGB LED: %s", esp_err_to_name(ret));
    } else {
        // WS2812 latches the transmitted pixel after a low reset interval.
        esp_rom_delay_us(80);
    }
    return ret;
}
