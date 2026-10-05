/**
 * @file board_i2c.h
 * @brief Shared onboard I2C bus (touch controller + IMU) for boards with a
 * display (ESP32-C6-Touch-LCD-1.47)
 */

#ifndef BOARD_I2C_H
#define BOARD_I2C_H

#include "driver/i2c_master.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Get the shared I2C master bus, creating it lazily on first call
 * @return Bus handle, or NULL if the bus could not be created
 */
i2c_master_bus_handle_t board_i2c_bus(void);

#ifdef __cplusplus
}
#endif

#endif /* BOARD_I2C_H */
