/**
 * @file led_controller.h
 * @brief Onboard LED control interface for ESP32
 * 
 * Controls the onboard LED with support for solid on/off
 * and blinking patterns (fast/slow).
 */

#ifndef LED_CONTROLLER_H
#define LED_CONTROLLER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize LED controller
 * @param pin GPIO pin number for the LED
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t led_init(uint8_t pin);

/**
 * @brief Turn LED ON (solid)
 */
void led_on(void);

/**
 * @brief Turn LED OFF
 */
void led_off(void);

/**
 * @brief Blink LED at high frequency (~5Hz)
 * Used for error state (no commands from host)
 */
void led_blink_fast(void);

/**
 * @brief Blink LED at low frequency (~1Hz)
 * Used for idle state (waiting for commands)
 */
void led_blink_slow(void);

/**
 * @brief Set LED PWM brightness (0-255)
 * @param brightness Brightness level (0 = off, 255 = full)
 */
void led_set_pwm(uint8_t brightness);

/**
 * @brief Stop all LED patterns and set to a specific state
 * @param state "ON", "OFF", "BLINK_FAST", or "BLINK_SLOW"
 */
void led_set_pattern(const char *pattern);

#ifdef __cplusplus
}
#endif

#endif /* LED_CONTROLLER_H */
