/**
 * @file display_text.c
 * @brief Pure text helpers for the display (see display_text.h).
 */

#include "display_text.h"

size_t display_text_utf8_decode(const char *text, uint32_t *out, size_t max_out)
{
    size_t count = 0;
    const uint8_t *s = (const uint8_t *)text;
    while (s[0] != 0 && count < max_out) {
        uint8_t b0 = s[0];
        if (b0 < 0x80) {
            out[count++] = b0;
            s += 1;
        } else if ((b0 & 0xE0) == 0xC0 &&
                   s[1] != 0 && (s[1] & 0xC0) == 0x80) {
            out[count++] = ((uint32_t)(b0 & 0x1F) << 6) | (s[1] & 0x3F);
            s += 2;
        } else if ((b0 & 0xF0) == 0xE0 &&
                   s[1] != 0 && s[2] != 0 &&
                   (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) {
            out[count++] = ((uint32_t)(b0 & 0x0F) << 12) |
                           ((uint32_t)(s[1] & 0x3F) << 6) |
                           (s[2] & 0x3F);
            s += 3;
        } else if ((b0 & 0xF8) == 0xF0 &&
                   s[1] != 0 && s[2] != 0 && s[3] != 0 &&
                   (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80 &&
                   (s[3] & 0xC0) == 0x80) {
            /* 4-byte sequences (emoji, ...): one code point, not four '?'s */
            out[count++] = ((uint32_t)(b0 & 0x07) << 18) |
                           ((uint32_t)(s[1] & 0x3F) << 12) |
                           ((uint32_t)(s[2] & 0x3F) << 6) |
                           (s[3] & 0x3F);
            s += 4;
        } else {
            /* Invalid or truncated sequence: one replacement character. */
            out[count++] = '?';
            s += 1;
        }
    }
    return count;
}

void display_text_layout(const uint32_t *cps, size_t len,
                         int cols, int max_lines,
                         display_text_layout_t *out)
{
    display_text_layout_t *result = out;
    int line_count = 0;

    for (int i = 0; i < max_lines; i++) {
        result->line_start[i] = 0;
        result->line_len[i] = 0;
    }
    result->line_count = 0;

    if (len == 0 || cols <= 0 || max_lines <= 0) {
        return;
    }

    /* Process each newline-delimited segment independently so a '\n' always
     * breaks the line instead of wrapping into a (blank) glyph. */
    size_t seg = 0;
    while (seg <= len && line_count < max_lines) {
        size_t seg_end = seg;
        while (seg_end < len && cps[seg_end] != '\n') {
            seg_end++;
        }

        /* Word-wrap the segment cps[seg..seg_end) */
        size_t i = seg;
        size_t cur_start = seg;
        size_t cur_len = 0;
        while (i < seg_end && line_count < max_lines) {
            size_t word_start = i;
            while (i < seg_end && cps[i] != ' ') {
                i++;
            }
            size_t word_len = i - word_start;
            while (i < seg_end && cps[i] == ' ') {
                i++;
            }

            if (word_len > (size_t)cols) {
                /* Hard-split words longer than a full line */
                if (cur_len > 0) {
                    result->line_start[line_count] = cur_start;
                    result->line_len[line_count] = cur_len;
                    line_count++;
                }
                while (word_len > (size_t)cols && line_count < max_lines) {
                    result->line_start[line_count] = word_start;
                    result->line_len[line_count] = (size_t)cols;
                    line_count++;
                    word_start += (size_t)cols;
                    word_len -= (size_t)cols;
                }
                cur_start = word_start;
                cur_len = (word_start < seg_end) ? word_len : 0;
            } else if (cur_len == 0) {
                cur_start = word_start;
                cur_len = word_len;
            } else if (cur_len + 1 + word_len <= (size_t)cols) {
                cur_len += 1 + word_len;
            } else if (line_count < max_lines) {
                result->line_start[line_count] = cur_start;
                result->line_len[line_count] = cur_len;
                line_count++;
                cur_start = word_start;
                cur_len = word_len;
            } else {
                break; /* line budget exhausted; drop the rest of the word */
            }
        }
        if (line_count < max_lines &&
            (cur_len > 0 || seg_end < len)) {
            /* An empty segment (from a '\n\n' or spaces) yields a blank
             * line; a trailing newline at the end of the text does not. */
            result->line_start[line_count] = cur_start;
            result->line_len[line_count] = cur_len;
            line_count++;
        }

        seg = seg_end + 1; /* skip the newline (or run past the end) */
    }

    result->line_count = line_count;
}
