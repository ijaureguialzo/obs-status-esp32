/**
 * @file imu_qmi8658.h
 * @brief Minimal QMI8658A accelerometer driver (display boards only)
 *
 * Used to auto-rotate the screen between the two landscape orientations
 * (USB connector on the right or on the left).
 */

#ifndef IMU_QMI8658_H
#define IMU_QMI8658_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Add the IMU to the shared board I2C bus and configure it
 * @return ESP_OK on success, ESP_ERR_NOT_FOUND if the chip does not answer
 */
esp_err_t imu_init(void);

/**
 * @brief Read one accelerometer sample
 * @param ax_g, ay_g, az_g acceleration in g (chip axes)
 * @return true on success (false when there is no fresh sample yet)
 */
bool imu_read_accel(float *ax_g, float *ay_g, float *az_g);

/**
 * @brief Diagnostic info: last STATUS0 register value and whether the last
 * I2C transaction failed
 */
void imu_get_diag(uint8_t *status0, bool *bus_error);

#ifdef __cplusplus
}
#endif

#endif /* IMU_QMI8658_H */
