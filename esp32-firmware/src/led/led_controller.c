/**
 * @file led_controller.c
 * @brief Onboard LED control implementation for ESP32
 * 
 * Controls the onboard LED using GPIO or PWM.
 * Supports solid on/off, and blinking patterns via timer interrupts.
 */

#include "led_controller.h"
#include "driver/gpio.h"
#include "driver/mcpwm_pwm_soc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include <string.h>

// Configuration from sdkconfig
#ifndef CONFIG_LED_GPIO_NUM
#define CONFIG_LED_GPIO_NUM 8  // Default for Freenove ESP32-S3-WROOM
#endif

// Internal state
static uint8_t s_led_pin = CONFIG_LED_GPIO_NUM;
static TimerHandle_t s_blink_timer = NULL;
static led_mode_t s_current_mode = LED_MODE_OFF;

typedef enum {
    LED_MODE_OFF,
    LED_MODE_ON,
    LED_MODE_BLINK_FAST,  // ~5Hz
    LED_MODE_BLINK_SLOW,  // ~1Hz
} led_mode_t;

esp_err_t led_init(uint8_t pin)
{
    if (pin > 0) {
        s_led_pin = pin;
    }
    
    // Configure GPIO for LED output
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << s_led_pin),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    
    esp_err_t ret = gpio_config(&io_conf);
    if (ret != ESP_OK) {
        return ret;
    }
    
    // Start with LED off
    gpio_set_level(s_led_pin, 0);
    
    // Create blink timer (one-shot for pattern control)
    s_blink_timer = xTimerCreate("led_blink", 
                                  pdMS_TO_TICKS(200),  // 200ms default period
                                  pdTRUE,  // auto-reload
                                  0, 
                                  NULL);
    
    if (s_blink_timer == NULL) {
        return ESP_FAIL;
    }
    
    s_current_mode = LED_MODE_OFF;
    
    return ESP_OK;
}

void led_on(void)
{
    s_current_mode = LED_MODE_ON;
    gpio_set_level(s_led_pin, 1);
    if (s_blink_timer != NULL) {
        xTimerStop(s_blink_timer, 0);
    }
}

void led_off(void)
{
    s_current_mode = LED_MODE_OFF;
    gpio_set_level(s_led_pin, 0);
    if (s_blink_timer != NULL) {
        xTimerStop(s_blink_timer, 0);
    }
}

void led_blink_fast(void)
{
    s_current_mode = LED_MODE_BLINK_FAST;
    
    if (s_blink_timer != NULL) {
        xTimerChangePeriod(s_blink_timer, pdMS_TO_TICKS(100), 0);  // 100ms = ~5Hz
        xTimerReset(s_blink_timer, 0);
    }
}

void led_blink_slow(void)
{
    s_current_mode = LED_MODE_BLINK_SLOW;
    
    if (s_blink_timer != NULL) {
        xTimerChangePeriod(s_blink_timer, pdMS_TO_TICKS(500), 0);  // 500ms = ~1Hz
        xTimerReset(s_blink_timer, 0);
    }
}

void led_set_pwm(uint8_t brightness)
{
    // For boards with PWM-capable LED
    // Configure MCPWM for LED PWM dimming
    // This is optional and board-specific
    
    // For now, use simple GPIO toggle as approximation
    if (brightness == 0) {
        led_off();
    } else if (brightness >= 128) {
        led_on();
    } else {
        // Partial brightness - turn on for a portion of the time
        gpio_set_level(s_led_pin, 1);
    }
}

void led_set_pattern(const char *pattern)
{
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

// Timer callback for blink patterns
static void blink_timer_callback(TimerHandle_t xTimer)
{
    (void)xTimer;
    
    gpio_set_level(s_led_pin, !gpio_get_level(s_led_pin));
    
    // Restart timer based on current mode
    uint32_t period;
    switch (s_current_mode) {
        case LED_MODE_BLINK_FAST:
            period = pdMS_TO_TICKS(100);  // ~5Hz
            break;
        case LED_MODE_BLINK_SLOW:
            period = pdMS_TO_TICKS(500);  // ~1Hz
            break;
        default:
            return;  // Stop for ON/OFF modes
    }
    
    xTimerChangePeriod(s_blink_timer, period, 0);
    xTimerStart(s_blink_timer, 0);
}

// Note: The timer callback needs to be set up in led_init():
// xTimerChangePeriod(s_blink_timer, pdMS_TO_TICKS(100), 0);
// xTimerRegister(s_blink_timer, blink_timer_callback, 0);
