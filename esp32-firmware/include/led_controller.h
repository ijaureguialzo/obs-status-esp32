/**
 * @file led_controller.h
 * @brief Onboard LED control interface for ESP32
 */

#ifndef LED_CONTROLLER_H
#define LED_CONTROLLER_H

#include <stdint.h>
#include <stdbool.h>
#include <esp_err.h>

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t led_init(uint8_t pin);
void led_on(void);
void led_off(void);
void led_blink_fast(void);
void led_blink_slow(void);
void led_set_color(uint8_t red, uint8_t green, uint8_t blue);
void led_set_pattern(const char *pattern);
bool led_is_on(void);

#ifdef __cplusplus
}
#endif

#endif /* LED_CONTROLLER_H */
