/**
 * @file touch_controller.h
 * @brief Touch input for boards with a touch screen (ESP32-C6-Touch-LCD-1.47)
 *
 * A tap anywhere on the screen emits the EVENT:TOGGLE_PAUSE protocol event
 * so the macOS app can pause/resume the OBS recording.
 *
 * On boards without a touch screen (CONFIG_BOARD_HAS_DISPLAY undefined)
 * touch_init() is a no-op.
 */

#ifndef TOUCH_CONTROLLER_H
#define TOUCH_CONTROLLER_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the touch controller and start the polling task
 * @return ESP_OK on success (or when the board has no touch screen)
 */
esp_err_t touch_init(void);

#ifdef __cplusplus
}
#endif

#endif /* TOUCH_CONTROLLER_H */
