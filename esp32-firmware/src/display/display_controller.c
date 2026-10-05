/**
 * @file display_controller.c
 * @brief LCD display control for the Waveshare ESP32-C6-Touch-LCD-1.47
 *
 * Panel: JD9853 (ST7789 command compatible) over SPI, driven in landscape
 * (320x172, USB connector on the right) via MADCTL MV+MY. The visible
 * window starts at GRAM column 34, hence the Y gap after swapping axes.
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

#include "esp_log.h"
#include "esp_check.h"
#include "driver/spi_master.h"
#include "driver/ledc.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_jd9853.h"

#include "font8x8_basic.h"

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
/* Logical (landscape) resolution after swapping axes */
#define LCD_H_RES          320
#define LCD_V_RES          172
/* The JD9853 GRAM is 240 px wide but only columns 34..205 are visible; after
 * swap_xy the column addresses are driven by the Y window, so the gap moves
 * to the Y axis. */
#define LCD_GAP_X          0
#define LCD_GAP_Y          34

#define BL_LEDC_TIMER      LEDC_TIMER_0
#define BL_LEDC_CHANNEL    LEDC_CHANNEL_0
#define BL_LEDC_DUTY_RES   LEDC_TIMER_10_BIT
#define BL_LEDC_FREQ_HZ    5000
#define BL_BRIGHTNESS_PCT  100

/* Text layout: 8x8 glyphs at 2x scale -> 16x16 cells, 10 columns */
#define FONT_SCALE   2
#define GLYPH_SIZE   8
#define CELL_SIZE    (GLYPH_SIZE * FONT_SCALE)
#define TEXT_COLS    (LCD_H_RES / CELL_SIZE)
#define TEXT_MAX_LINES (LCD_V_RES / CELL_SIZE)

/* SPI transfers are done in horizontal bands to bound RAM usage */
#define BAND_LINES 20

#define SCENE_MAX_LEN 96

static esp_lcd_panel_handle_t s_panel = NULL;
static SemaphoreHandle_t s_mutex = NULL;

static uint8_t s_bg_red;
static uint8_t s_bg_green;
static uint8_t s_bg_blue;
static char s_scene[SCENE_MAX_LEN];

/* 1-bit offscreen text mask; set bits are drawn in the text color */
static uint8_t s_text_mask[LCD_H_RES * LCD_V_RES / 8];
/* Reusable DMA-capable band buffer */
static uint16_t s_band[LCD_H_RES * BAND_LINES];

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

static bool mask_get_pixel(int x, int y)
{
    return (s_text_mask[(y * LCD_H_RES + x) / 8] >> ((y * LCD_H_RES + x) % 8)) & 1u;
}

/* Rebuild s_text_mask from s_scene with word wrapping and centering */
static void layout_text(void)
{
    memset(s_text_mask, 0, sizeof(s_text_mask));

    size_t len = strlen(s_scene);
    if (len == 0) {
        return;
    }

    int line_count = (int)((len + TEXT_COLS - 1) / TEXT_COLS);
    if (line_count > TEXT_MAX_LINES) {
        line_count = TEXT_MAX_LINES;
        len = (size_t)line_count * TEXT_COLS;
    }
    int origin_y = (LCD_V_RES - line_count * CELL_SIZE) / 2;

    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s_scene[i];
        if (c >= 128) {
            c = '?';
        }
        const char *glyph = font8x8_basic[c];

        int line = (int)(i / TEXT_COLS);
        int col = (int)(i % TEXT_COLS);
        int cell_x = col * CELL_SIZE;
        int cell_y = origin_y + line * CELL_SIZE;

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

    for (int y0 = 0; y0 < LCD_V_RES; y0 += BAND_LINES) {
        int lines = (y0 + BAND_LINES <= LCD_V_RES) ? BAND_LINES : LCD_V_RES - y0;
        for (int y = 0; y < lines; y++) {
            for (int x = 0; x < LCD_H_RES; x++) {
                s_band[y * LCD_H_RES + x] = mask_get_pixel(x, y0 + y) ? fg_wire : bg_wire;
            }
        }
        esp_lcd_panel_draw_bitmap(s_panel, 0, y0, LCD_H_RES, y0 + lines, s_band);
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
    /* Landscape with the USB connector on the right: swap axes (MV) and
     * mirror the row counter (MY) so logical Y walks the visible GRAM
     * columns from 205 down to 34. */
    ESP_RETURN_ON_ERROR(esp_lcd_panel_swap_xy(s_panel, true), TAG, "Swap XY failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_mirror(s_panel, false, true), TAG, "Mirror failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_set_gap(s_panel, LCD_GAP_X, LCD_GAP_Y), TAG, "Gap failed");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(s_panel, true), TAG, "Display on failed");

    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "Backlight init failed");

    ESP_LOGI(TAG, "Display initialized (%dx%d)", LCD_H_RES, LCD_V_RES);
    display_set_background(0, 0, 0);
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
    redraw_locked();
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
    redraw_locked();
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
