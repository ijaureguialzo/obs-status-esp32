/**
 * @file display_controller.h
 * @brief LCD display control for boards with a screen (ESP32-C6-Touch-LCD-1.47)
 *
 * The display mirrors the LED state: while OBS is recording the background
 * is filled with the selected recording color and the active OBS scene name
 * is shown on top of it.
 *
 * On boards without a display (CONFIG_BOARD_HAS_DISPLAY undefined) every
 * function is a no-op so the rest of the firmware can call it
 * unconditionally.
 */

#ifndef DISPLAY_CONTROLLER_H
#define DISPLAY_CONTROLLER_H

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the LCD panel, backlight and rendering state
 * @return ESP_OK on success (or when the board has no display)
 */
esp_err_t display_init(void);

/**
 * @brief Fill the screen background with an RGB color
 *
 * Used to mirror the LED color while recording. Pass 0,0,0 to blank.
 */
void display_set_background(uint8_t red, uint8_t green, uint8_t blue);

/**
 * @brief Set the OBS scene name shown on screen
 *
 * Pass an empty string or NULL to clear the label. Non-ASCII bytes are
 * rendered as '?'.
 */
void display_set_scene(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* DISPLAY_CONTROLLER_H */
