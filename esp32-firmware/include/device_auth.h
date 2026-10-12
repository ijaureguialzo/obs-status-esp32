/**
 * @file device_auth.h
 * @brief Per-device shared secret for authenticating the host
 *
 * The text protocol travels an unauthenticated USB link, so a look-alike
 * serial device could in principle drive the host (e.g. toggle the OBS
 * recording pause). To close that vector the firmware keeps a random
 * 16-byte secret (32 hex chars) in NVS, generated on first boot. The host
 * must answer `AUTH:<secret>` with the stored value to earn trust; the
 * secret is shown in the boot log (and on the boot screen of display
 * boards) so the user can read it once and enter it in the app.
 */

#ifndef DEVICE_AUTH_H
#define DEVICE_AUTH_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DEVICE_AUTH_SECRET_LEN 32 /* 16 random bytes, lowercase hex */

/**
 * Load the secret from NVS, generating and persisting one on first boot.
 * Must run after nvs_flash_init(); the returned value is then immutable.
 */
esp_err_t device_auth_init(void);

/**
 * The stored secret (lowercase hex, NUL-terminated) for display to the user.
 */
const char *device_auth_secret(void);

/**
 * Constant-time compare of a candidate secret (case-insensitive).
 */
bool device_auth_check(const char *candidate);

#ifdef __cplusplus
}
#endif

#endif /* DEVICE_AUTH_H */
