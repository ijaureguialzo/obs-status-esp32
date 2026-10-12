/**
 * @file device_auth.c
 * @brief Per-device shared secret stored in NVS (see device_auth.h)
 *
 * The secret is generated once (first boot) and never changes, so a
 * device that was trusted keeps being the same device. s_secret is written
 * only during device_auth_init() and read-only afterwards; the protocol
 * parser (app task) is the only reader at runtime.
 */

#include "device_auth.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "nvs.h"

static const char *TAG = "device-auth";

#define NVS_NAMESPACE "obs_status"
#define NVS_SECRET_KEY "auth_secret"

static char s_secret[DEVICE_AUTH_SECRET_LEN + 1];

esp_err_t device_auth_init(void)
{
    nvs_handle_t handle;

    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle);
    if (ret == ESP_OK) {
        size_t len = sizeof(s_secret);
        ret = nvs_get_str(handle, NVS_SECRET_KEY, s_secret, &len);
        nvs_close(handle);
    }

    if (ret != ESP_OK || s_secret[0] == '\0') {
        /* First boot: generate and persist a fresh secret */
        uint8_t raw[DEVICE_AUTH_SECRET_LEN / 2];
        esp_fill_random(raw, sizeof(raw));
        for (size_t i = 0; i < sizeof(raw); i++) {
            snprintf(s_secret + 2 * i, 3, "%02x", raw[i]);
        }
        s_secret[DEVICE_AUTH_SECRET_LEN] = '\0';

        if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
            ESP_LOGE(TAG, "Cannot open NVS to persist the auth secret");
            return ESP_FAIL;
        }
        ret = nvs_set_str(handle, NVS_SECRET_KEY, s_secret);
        if (ret == ESP_OK) {
            ret = nvs_commit(handle);
        }
        nvs_close(handle);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Could not persist the auth secret: %s", esp_err_to_name(ret));
            return ret;
        }
        ESP_LOGW(TAG, "First boot: generated a new device secret");
    }

    /* Shown on every boot: the user reads it once (serial monitor or boot
     * screen) and enters it in the app. */
    ESP_LOGI(TAG, "Device secret: %s", s_secret);
    return ESP_OK;
}

const char *device_auth_secret(void)
{
    return s_secret;
}

bool device_auth_check(const char *candidate)
{
    if (candidate == NULL || s_secret[0] == '\0') {
        return false;
    }
    const size_t len = strlen(s_secret);
    if (strlen(candidate) != len) {
        return false;
    }
    /* Constant-time, case-insensitive compare */
    int diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= tolower((unsigned char)candidate[i]) ^ tolower((unsigned char)s_secret[i]);
    }
    return diff == 0;
}
