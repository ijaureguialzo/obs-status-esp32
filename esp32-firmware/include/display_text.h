/**
 * @file display_text.h
 * @brief Pure text helpers for the display: UTF-8 decoding and word wrap.
 *
 * No ESP-IDF dependencies, so the same code runs in the host unit tests
 * (see test/test_display.c).
 */

#ifndef DISPLAY_TEXT_H
#define DISPLAY_TEXT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Upper bound of the layout tables; boards use fewer (e.g. 10 lines). */
#define DISPLAY_TEXT_MAX_LINES 16

/** Result of display_text_layout: one entry per wrapped line. */
typedef struct display_text_layout {
    /** Code point offset of the first character of each line. */
    size_t line_start[DISPLAY_TEXT_MAX_LINES];
    /** Number of code points in each line. */
    size_t line_len[DISPLAY_TEXT_MAX_LINES];
    /** Number of populated entries (<= max_lines). */
    int line_count;
} display_text_layout_t;

/**
 * Decode UTF-8 into code points (1- to 4-byte sequences); invalid or
 * truncated sequences become '?'. Stops at the first NUL byte or when
 * max_out code points have been written. Returns the number written.
 */
size_t display_text_utf8_decode(const char *text, uint32_t *out, size_t max_out);

/**
 * Word-wrap cps[0..len) for a screen of `cols` cells and up to `max_lines`
 * lines (both must be <= DISPLAY_TEXT_MAX_LINES):
 *  - an explicit '\n' code point always breaks the line (even mid-word),
 *  - other text wraps on spaces,
 *  - words longer than a full line are hard-split,
 *  - once the line budget is exhausted the rest of the text is dropped.
 * Centering is left to the caller, which uses the returned line lengths.
 */
void display_text_layout(const uint32_t *cps, size_t len,
                         int cols, int max_lines,
                         display_text_layout_t *out);

#ifdef __cplusplus
}
#endif

#endif /* DISPLAY_TEXT_H */
