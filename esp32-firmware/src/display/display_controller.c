/**
 * @file display_controller.c
 * @brief LCD display control for the Waveshare ESP32-C6-Touch-LCD-1.47
 *
 * Panel: JD9853 (ST7789 command compatible) over SPI. The landscape frame
 * (320x172) is rotated in software and streamed in the panel's native
 * portrait scan order, so the GRAM write front follows the panel refresh
 * scan and the redraw shows no diagonal tearing. Only GRAM columns 34..205
 * are visible (X gap 34).
 * Backlight: LEDC PWM on GPIO23 (active high).
 * Text: public domain 8x8 VGA bitmap font, rendered at 2x scale, centered.
 *
 * The whole implementation is compiled out unless CONFIG_BOARD_HAS_DISPLAY
 * is defined; the stubs at the bottom keep the API callable on LED-only
 * boards.
 */

#include "display_controller.h"

#if CONFIG_BOARD_HAS_DISPLAY

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_check.h"
#include "driver/spi_master.h"
#include "driver/ledc.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_jd9853.h"

#include "font8x8_basic.h"
#include "font8x8_ext_latin.h"
#include "firmware_version.h"
#include "imu_qmi8658.h"

static const char *TAG = "display";

/* Waveshare ESP32-C6-Touch-LCD-1.47 pinout (see vendor BSP) */
#define LCD_PIN_SCLK 1
#define LCD_PIN_MOSI 2
#define LCD_PIN_MISO 3
#define LCD_PIN_CS   14
#define LCD_PIN_DC   15
#define LCD_PIN_RST  22
#define LCD_PIN_BL   23

#define LCD_SPI_HOST       SPI2_HOST
#define LCD_PIXEL_CLOCK_HZ (80 * 1000 * 1000)
/* Logical (landscape) resolution */
#define LCD_H_RES          320
#define LCD_V_RES          172
/* Physical (portrait) GRAM streaming order: 172 columns x 320 rows. The
 * JD9853 GRAM is 240 px wide but only columns 34..205 are visible. */
#define LCD_PHYS_W         172
#define LCD_PHYS_H         320
#define LCD_GAP_X          34
#define LCD_GAP_Y          0

#define BL_LEDC_TIMER      LEDC_TIMER_0
#define BL_LEDC_CHANNEL    LEDC_CHANNEL_0
#define BL_LEDC_DUTY_RES   LEDC_TIMER_10_BIT
#define BL_LEDC_FREQ_HZ    5000
#define BL_BRIGHTNESS_PCT  100

/* Text layout: 8x8 glyphs at 2x scale -> 16x16 cells */
#define FONT_SCALE   2
#define GLYPH_SIZE   8
#define CELL_SIZE    (GLYPH_SIZE * FONT_SCALE)
#define TEXT_COLS    (LCD_H_RES / CELL_SIZE)
#define TEXT_MAX_LINES (LCD_V_RES / CELL_SIZE)

#define SCENE_MAX_LEN 96

/* Full-screen RGB565 frame (320x172x2 = 110 KB static): rendered in one shot
 * and pushed in a single DMA transfer, so a redraw is one fast uniform sweep
 * instead of visible band-by-band painting. */

/* Auto-rotation (QMI8658A): only the two landscape orientations are
 * supported; portrait or flat readings keep the current orientation. */
#define ORIENTATION_POLL_MS        150
#define ORIENTATION_STABLE_SAMPLES 4
#define ORIENTATION_MIN_G          0.65f
#define ORIENTATION_LOG_EVERY      13  /* ~2 s at the poll period */
/* The IMU Z axis is normal to the board, so a dominant Z means the board is
 * lying flat (ambiguous) and is ignored. The in-plane axis (X or Y) with the
 * strongest reading is the vertical one; its sign tells right from left.
 * Measured on this board: a positive reading means the USB connector is on
 * the right. If a board revision mounts the QMI8658 differently, flip this
 * define. */
#define IMU_USB_RIGHT_WHEN_NEGATIVE 0

static esp_lcd_panel_handle_t s_panel = NULL;
static SemaphoreHandle_t s_mutex = NULL;

static uint8_t s_bg_red;
static uint8_t s_bg_green;
static uint8_t s_bg_blue;
static char s_scene[SCENE_MAX_LEN];
static bool s_usb_right = true;

/* A redraw is expensive (full-frame software rotation + a 110 KB SPI
 * transfer) on the single-core C6, so state setters only mark the frame
 * dirty and one task repaints at most once per poll period. This
 * coalesces bursts (scene + background + orientation changing together)
 * into a single redraw. Guarded by s_mutex. */
#define REFRESH_POLL_MS 30
static bool s_redraw_pending = false;

/* 1-bit offscreen text mask; set bits are drawn in the text color */
static uint8_t s_text_mask[LCD_H_RES * LCD_V_RES / 8];
/* Full frame buffer, DMA-capable */
static uint16_t s_frame[LCD_H_RES * LCD_V_RES];

static uint16_t rgb565(uint8_t red, uint8_t green, uint8_t blue)
{
    return (uint16_t)(((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3));
}

static void mask_set_pixel(int x, int y)
{
    if (x < 0 || x >= LCD_H_RES || y < 0 || y >= LCD_V_RES) {
        return;
    }
    s_text_mask[(y * LCD_H_RES + x) / 8] |= (uint8_t)(1u << ((y * LCD_H_RES + x) % 8));
}

/* Look up the 8x8 glyph for a Unicode code point: basic Latin from
 * font8x8_basic, Latin-1 supplement (U+00A0-U+00FF) from font8x8_ext_latin,
 * anything else falls back to '?'. */
static const char *glyph_for(uint32_t cp)
{
    if (cp < 0x80) {
        return font8x8_basic[cp];
    }
    if (cp >= 0xA0 && cp <= 0xFF) {
        return font8x8_ext_latin[cp - 0xA0];
    }
    return font8x8_basic['?'];
}

/* Decode UTF-8 into code points; invalid bytes become '?'. */
static size_t utf8_decode(const char *text, uint32_t *out, size_t max_out)
{
    size_t count = 0;
    for (size_t i = 0; text[i] != '\0' && count < max_out; ) {
        uint8_t b0 = (uint8_t)text[i];
        if (b0 < 0x80) {
            out[count++] = b0;
            i += 1;
        } else if ((b0 & 0xE0) == 0xC0 && (uint8_t)text[i + 1] != 0) {
            out[count++] = ((uint32_t)(b0 & 0x1F) << 6) | ((uint8_t)text[i + 1] & 0x3F);
            i += 2;
        } else if ((b0 & 0xF0) == 0xE0 && (uint8_t)text[i + 1] != 0 && (uint8_t)text[i + 2] != 0) {
            out[count++] = ((uint32_t)(b0 & 0x0F) << 12) |
                           (((uint8_t)text[i + 1] & 0x3F) << 6) |
                           ((uint8_t)text[i + 2] & 0x3F);
            i += 3;
        } else {
            out[count++] = '?';
            i += 1;
        }
    }
    return count;
}

static void draw_glyph(uint32_t cp, int cell_x, int cell_y)
{
    const char *glyph = glyph_for(cp);
    for (int gy = 0; gy < GLYPH_SIZE; gy++) {
        for (int gx = 0; gx < GLYPH_SIZE; gx++) {
            if ((glyph[gy] >> gx) & 1u) {
                for (int sy = 0; sy < FONT_SCALE; sy++) {
                    for (int sx = 0; sx < FONT_SCALE; sx++) {
                        mask_set_pixel(cell_x + gx * FONT_SCALE + sx,
                                       cell_y + gy * FONT_SCALE + sy);
                    }
                }
            }
        }
    }
}

/* Rebuild s_text_mask from s_scene: wrap on word boundaries (long words are
 * hard-split), center each line horizontally and the block vertically. */
static void layout_text(void)
{
    memset(s_text_mask, 0, sizeof(s_text_mask));

    static uint32_t cps[SCENE_MAX_LEN];
    size_t len = utf8_decode(s_scene, cps, SCENE_MAX_LEN);
    if (len == 0) {
        return;
    }

    /* Wrapped lines: start offset and length in code points */
    size_t line_start[TEXT_MAX_LINES];
    size_t line_len[TEXT_MAX_LINES];
    int line_count = 0;

    size_t i = 0;
    size_t cur_start = 0;
    size_t cur_len = 0;
    while (i < len && line_count < TEXT_MAX_LINES) {
        /* Explicit line break (used by the boot screen) */
        if (cps[i] == '\n') {
            if (cur_len > 0) {
                line_start[line_count] = cur_start;
                line_len[line_count] = cur_len;
                line_count++;
            }
            i += 1;
            cur_start = i;
            cur_len = 0;
            continue;
        }

        /* Extract next word */
        size_t word_start = i;
        while (i < len && cps[i] != ' ') {
            i++;
        }
        size_t word_len = i - word_start;
        while (i < len && cps[i] == ' ') {
            i++;
        }

        if (word_len > TEXT_COLS) {
            /* Hard-split words longer than a full line */
            if (cur_len > 0) {
                line_start[line_count] = cur_start;
                line_len[line_count] = cur_len;
                line_count++;
                cur_len = 0;
            }
            while (word_len > TEXT_COLS && line_count < TEXT_MAX_LINES) {
                line_start[line_count] = word_start;
                line_len[line_count] = TEXT_COLS;
                line_count++;
                word_start += TEXT_COLS;
                word_len -= TEXT_COLS;
            }
            cur_start = word_start;
            cur_len = word_len;
        } else if (cur_len == 0) {
            cur_start = word_start;
            cur_len = word_len;
        } else if (cur_len + 1 + word_len <= TEXT_COLS) {
            cur_len += 1 + word_len;
        } else {
            line_start[line_count] = cur_start;
            line_len[line_count] = cur_len;
            line_count++;
            cur_start = word_start;
            cur_len = word_len;
        }
    }
    if (cur_len > 0 && line_count < TEXT_MAX_LINES) {
        line_start[line_count] = cur_start;
        line_len[line_count] = cur_len;
        line_count++;
    }

    if (line_count == 0) {
        return;
    }

    int origin_y = (LCD_V_RES - line_count * CELL_SIZE) / 2;
    for (int line = 0; line < line_count; line++) {
        int cell_x = (LCD_H_RES - (int)line_len[line] * CELL_SIZE) / 2;
        int cell_y = origin_y + line * CELL_SIZE;
        for (size_t j = 0; j < line_len[line]; j++) {
            draw_glyph(cps[line_start[line] + j], cell_x + (int)j * CELL_SIZE, cell_y);
        }
    }
}

static void redraw_locked(void)
{
    if (s_panel == NULL) {
        return;
    }

    layout_text();

    /* Pick a readable text color from the background luminance */
    unsigned int luminance = 299u * s_bg_red + 587u * s_bg_green + 114u * s_bg_blue;
    uint16_t bg = rgb565(s_bg_red, s_bg_green, s_bg_blue);
    uint16_t fg = rgb565(luminance > 128000u ? 0 : 255, luminance > 128000u ? 0 : 255, luminance > 128000u ? 0 : 255);
    uint16_t bg_wire = (uint16_t)((bg >> 8) | (bg << 8));
    uint16_t fg_wire = (uint16_t)((fg >> 8) | (fg << 8));

    /* Compose the frame rotated into the panel's native portrait order
     * (column index fastest). Writing the GRAM in scan-out order keeps the
     * write front aligned with the refresh, so the color change appears as
     * a fast uniform sweep instead of a diagonal wipe.
     *
     * Mapping (equivalent to the previous MADCTL landscape setup; verified
     * on hardware):
     *   USB right: physical(row, col+34) <- logical(row, 171-col)
     *   USB left:  physical(row, col+34) <- logical(319-row, col) */
    const bool usb_right = s_usb_right;
    for (int row = 0; row < LCD_PHYS_H; row++) {
        uint16_t *out = &s_frame[row * LCD_PHYS_W];
        for (int col = 0; col < LCD_PHYS_W; col++) {
            const int lx = usb_right ? row : (LCD_H_RES - 1 - row);
            const int ly = usb_right ? (LCD_V_RES - 1 - col) : col;
            const int idx = ly * LCD_H_RES + lx;
            out[col] = ((s_text_mask[idx / 8] >> (idx % 8)) & 1u) ? fg_wire : bg_wire;
        }
    }
    esp_lcd_panel_draw_bitmap(s_panel, 0, 0, LCD_PHYS_W, LCD_PHYS_H, s_frame);
}

/* Orientation is applied purely in software when composing the frame (see
 * redraw_locked), so switching sides just marks the frame dirty — no panel
 * commands. USB right and USB left differ by a 180 degree rotation of the
 * mapping. */

/* Redraws the screen when the frame is dirty. A dedicated task keeps the
 * expensive repaint out of the protocol/touch/IMU tasks and coalesces
 * back-to-back state changes. */
static void refresh_task(void *pv_parameters)
{
    (void)pv_parameters;
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(REFRESH_POLL_MS));
        if (s_mutex == NULL) {
            continue;
        }
        if (xSemaphoreTake(s_mutex, 0) == pdTRUE) {
            if (s_redraw_pending && s_panel != NULL) {
                s_redraw_pending = false;
                redraw_locked();
            }
            xSemaphoreGive(s_mutex);
        }
    }
}

static float absf_local(float v)
{
    return v < 0.0f ? -v : v;
}

/* Polls the IMU and flips the screen between the two landscape orientations.
 * The vertical in-plane axis must dominate clearly; a dominant Z (board
 * lying flat) or weak readings are ambiguous and keep the current
 * orientation. */
static void orientation_task(void *pv_parameters)
{
    (void)pv_parameters;
    int stable_count = 0;
    int log_countdown = 0;
    bool desired = s_usb_right;

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(ORIENTATION_POLL_MS));

        float ax, ay, az;
        if (!imu_read_accel(&ax, &ay, &az)) {
            if (log_countdown-- <= 0) {
                log_countdown = ORIENTATION_LOG_EVERY;
                uint8_t status0;
                bool bus_error;
                imu_get_diag(&status0, &bus_error);
                ESP_LOGW(TAG, "accel read failed (STATUS0=0x%02x bus_error=%d)",
                         status0, bus_error);
            }
            continue;
        }

        if (log_countdown-- <= 0) {
            log_countdown = ORIENTATION_LOG_EVERY;
            /* DEBUG: this fires every ~2 s and shares the USB console with
             * the protocol; raise the host log level to see it. */
            ESP_LOGD(TAG, "accel ax=%.2f ay=%.2f az=%.2f", ax, ay, az);
        }

        const float abs_x = absf_local(ax);
        const float abs_y = absf_local(ay);
        const float abs_z = absf_local(az);

        if (abs_z >= abs_x && abs_z >= abs_y) {
            /* Lying flat on the desk: no reliable left/right reading */
            stable_count = 0;
            continue;
        }

        /* The dominant in-plane axis is the vertical one */
        const float vertical = (abs_x > abs_y) ? ax : ay;
        if (absf_local(vertical) < ORIENTATION_MIN_G) {
            stable_count = 0;
            continue;
        }

        const bool new_desired = (vertical < 0.0f) == (IMU_USB_RIGHT_WHEN_NEGATIVE != 0);
        if (new_desired != desired) {
            desired = new_desired;
            stable_count = 1;
        } else if (desired != s_usb_right && ++stable_count >= ORIENTATION_STABLE_SAMPLES) {
            stable_count = 0;
            if (xSemaphoreTake(s_mutex, portMAX_DELAY) == pdTRUE) {
                s_usb_right = desired;
                s_redraw_pending = true;
                ESP_LOGI(TAG, "Orientation changed: USB %s (ax=%.2f ay=%.2f az=%.2f)",
                         s_usb_right ? "right" : "left", ax, ay, az);
                xSemaphoreGive(s_mutex);
            }
        }
    }
}

static esp_err_t backlight_init(void)
{
    const ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_num = BL_LEDC_TIMER,
        .duty_resolution = BL_LEDC_DUTY_RES,
        .freq_hz = BL_LEDC_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_RETURN_ON_ERROR(ledc_timer_config(&timer), TAG, "LEDC timer config failed");

    const ledc_channel_config_t channel = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = BL_LEDC_CHANNEL,
        .timer_sel = BL_LEDC_TIMER,
        .intr_type = LEDC_INTR_DISABLE,
        .gpio_num = LCD_PIN_BL,
        .duty = (1 << 10) - 1, /* start at full brightness */
        .hpoint = 0,
    };
    ESP_RETURN_ON_ERROR(ledc_channel_config(&channel), TAG, "LEDC channel config failed");
    return ESP_OK;
}

esp_err_t display_init(void)
{
    s_mutex = xSemaphoreCreateMutex();
    if (s_mutex == NULL) {
        return ESP_ERR_NO_MEM;
    }

    const spi_bus_config_t bus_config = {
        .sclk_io_num = LCD_PIN_SCLK,
        .mosi_io_num = LCD_PIN_MOSI,
        .miso_io_num = LCD_PIN_MISO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_SPI_HOST, &bus_config, SPI_DMA_CH_AUTO),
                        TAG, "SPI bus init failed");

    esp_lcd_panel_io_handle_t io_handle = NULL;
    esp_lcd_panel_io_spi_config_t io_config = JD9853_PANEL_IO_SPI_CONFIG(LCD_PIN_CS, LCD_PIN_DC, NULL, NULL);
    io_config.pclk_hz = LCD_PIXEL_CLOCK_HZ;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_SPI_HOST, &io_config, &io_handle),
                        TAG, "Panel IO init failed");

    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = LCD_PIN_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_jd9853(io_handle, &panel_config, &s_panel),
                        TAG, "Panel init failed");

    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "Panel reset failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "Panel init sequence failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(s_panel, true), TAG, "Color invert failed");
    /* Native portrait order; only GRAM columns 34..205 are visible */
    ESP_RETURN_ON_ERROR(esp_lcd_panel_set_gap(s_panel, LCD_GAP_X, LCD_GAP_Y), TAG, "Gap failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(s_panel, true), TAG, "Display on failed");

    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "Backlight init failed");

    if (xTaskCreate(refresh_task, "display_rf", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGW(TAG, "Could not start display refresh task");
    }

    /* Auto-rotate between the two landscape orientations using the IMU;
     * if the chip does not answer, the screen stays in the default
     * (USB on the right) orientation. */
    if (imu_init() == ESP_OK) {
        if (xTaskCreate(orientation_task, "display_orient", 3072, NULL, 4, NULL) != pdPASS) {
            ESP_LOGW(TAG, "Could not start orientation task");
        }
    } else {
        ESP_LOGW(TAG, "IMU not available - auto-rotation disabled");
    }

    ESP_LOGI(TAG, "Display initialized (%dx%d)", LCD_H_RES, LCD_V_RES);
    display_set_background(0, 0, 0);

    /* Boot screen: title and version, centered. It is replaced by the first
     * background/scene pushed by the host (an empty scene blanks it). */
    char boot[64];
    snprintf(boot, sizeof(boot), "OBS Status\nv%s (%s)",
             FIRMWARE_VERSION, FIRMWARE_BUILD);
    display_set_scene(boot);
    return ESP_OK;
}

void display_set_background(uint8_t red, uint8_t green, uint8_t blue)
{
    if (s_mutex == NULL || xSemaphoreTake(s_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    s_bg_red = red;
    s_bg_green = green;
    s_bg_blue = blue;
    s_redraw_pending = true;
    xSemaphoreGive(s_mutex);
}

void display_set_scene(const char *name)
{
    if (s_mutex == NULL || xSemaphoreTake(s_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }
    if (name == NULL) {
        name = "";
    }
    strncpy(s_scene, name, sizeof(s_scene) - 1);
    s_scene[sizeof(s_scene) - 1] = '\0';
    s_redraw_pending = true;
    xSemaphoreGive(s_mutex);
}

#else /* !CONFIG_BOARD_HAS_DISPLAY */

esp_err_t display_init(void)
{
    return ESP_OK;
}

void display_set_background(uint8_t red, uint8_t green, uint8_t blue)
{
    (void)red;
    (void)green;
    (void)blue;
}

void display_set_scene(const char *name)
{
    (void)name;
}

#endif /* CONFIG_BOARD_HAS_DISPLAY */
