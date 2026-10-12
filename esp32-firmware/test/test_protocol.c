/**
 * @file test_protocol.c
 * @brief Host-side unit tests for the dependency-free firmware modules:
 *        - protocol_message: text command parsing
 *        - protocol_line_buffer: byte stream line assembly
 *        - display_text: UTF-8 decoding and text layout
 *
 * Run with: pio test -e host-tests -d esp32-firmware
 *
 * The modules under test are pulled in directly; they have no
 * FreeRTOS / ESP-IDF dependencies. (PlatformIO discovers test cases as
 * files directly inside test/, so both suites live in this file.)
 */

#include "unity.h"

#include "protocol_message.h"
#include "protocol_line_buffer.h"
#include "display_text.h"

#include <string.h>

#include "../src/protocol/protocol_message.c"
#include "../src/display/display_text.c"
#include "../src/protocol/protocol_line_buffer.c"

/* ==============================
 * protocol_message
 * ============================== */

static protocol_message_t msg;

void test_bare_led_on_uses_default_color(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("LED_ON", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_LED_ON, msg.type);
    TEST_ASSERT_FALSE(msg.has_color);
}

void test_led_on_with_color(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("LED_ON:255,128,0", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_LED_ON, msg.type);
    TEST_ASSERT_TRUE(msg.has_color);
    TEST_ASSERT_EQUAL(255, msg.red);
    TEST_ASSERT_EQUAL(128, msg.green);
    TEST_ASSERT_EQUAL(0, msg.blue);
}

void test_led_on_with_zero_color(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("LED_ON:0,0,0", &msg));
    TEST_ASSERT_TRUE(msg.has_color);
    TEST_ASSERT_EQUAL(0, msg.red);
    TEST_ASSERT_EQUAL(0, msg.green);
    TEST_ASSERT_EQUAL(0, msg.blue);
}

void test_led_on_color_out_of_range_is_invalid(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_INVALID_FORMAT, protocol_message_parse("LED_ON:256,0,0", &msg));
}

void test_led_on_color_incomplete_is_invalid(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_INVALID_FORMAT, protocol_message_parse("LED_ON:1,2", &msg));
}

void test_led_on_color_trailing_junk_is_invalid(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_INVALID_FORMAT, protocol_message_parse("LED_ON:1,2,3x", &msg));
}

void test_led_on_negative_component_is_invalid(void)
{
    /* "-1" parses as a huge unsigned value, which is out of range */
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_INVALID_FORMAT, protocol_message_parse("LED_ON:-1,0,0", &msg));
}

void test_led_off(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("LED_OFF", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_LED_OFF, msg.type);
}

void test_blink_fast(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("BLINK_FAST", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_BLINK_FAST, msg.type);
}

void test_blink_slow(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("BLINK_SLOW", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_BLINK_SLOW, msg.type);
}

void test_status(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("STATUS", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_STATUS, msg.type);
}

void test_scene(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("SCENE:My Scene", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_SCENE, msg.type);
    TEST_ASSERT_EQUAL_STRING("My Scene", msg.scene);
}

void test_scene_with_spaces_and_utf8(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("SCENE:Escena 日本語", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_SCENE, msg.type);
    TEST_ASSERT_EQUAL_STRING("Escena 日本語", msg.scene);
}

void test_empty_scene_clears_the_display(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("SCENE:", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_SCENE, msg.type);
    TEST_ASSERT_EQUAL_STRING("", msg.scene);
}

void test_auth_with_secret(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_OK, protocol_message_parse("AUTH:abcd1234ef56", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_AUTH, msg.type);
    TEST_ASSERT_EQUAL_STRING("abcd1234ef56", msg.secret);
}

void test_auth_empty_is_invalid(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_INVALID_FORMAT, protocol_message_parse("AUTH:", &msg));
}

void test_unknown_command(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_UNKNOWN_COMMAND, protocol_message_parse("GARBAGE", &msg));
}

void test_commands_are_case_sensitive(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_UNKNOWN_COMMAND, protocol_message_parse("led_on", &msg));
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_UNKNOWN_COMMAND, protocol_message_parse("Status", &msg));
}

void test_empty_line_is_unknown(void)
{
    TEST_ASSERT_EQUAL(PROTOCOL_MSG_UNKNOWN_COMMAND, protocol_message_parse("", &msg));
}

/* ==============================
 * protocol_line_buffer
 * ============================== */

#define MAX_LINES 8

static protocol_line_buffer_t lb;
static int line_count;
static char received[MAX_LINES][PROTOCOL_MAX_LINE_LENGTH];

static void on_line(const char *line)
{
    if (line_count < MAX_LINES) {
        strncpy(received[line_count], line, PROTOCOL_MAX_LINE_LENGTH - 1);
        received[line_count][PROTOCOL_MAX_LINE_LENGTH - 1] = '\0';
        line_count++;
    }
}

static void reset_line_captures(void)
{
    protocol_line_buffer_reset(&lb);
    line_count = 0;
    memset(received, 0, sizeof(received));
}

static void feed(const char *data)
{
    protocol_line_buffer_feed(&lb, (const uint8_t *)data, strlen(data), on_line);
}

void test_single_line(void)
{
    reset_line_captures();
    feed("LED_ON\n");
    TEST_ASSERT_EQUAL(1, line_count);
    TEST_ASSERT_EQUAL_STRING("LED_ON", received[0]);
}

void test_two_lines_in_one_chunk(void)
{
    reset_line_captures();
    feed("LED_ON\r\nLED_OFF\n");
    TEST_ASSERT_EQUAL(2, line_count);
    TEST_ASSERT_EQUAL_STRING("LED_ON", received[0]);
    TEST_ASSERT_EQUAL_STRING("LED_OFF", received[1]);
}

void test_line_split_across_chunks(void)
{
    reset_line_captures();
    feed("LED_");
    TEST_ASSERT_EQUAL(0, line_count);
    feed("ON:1,2,3");
    TEST_ASSERT_EQUAL(0, line_count);
    feed("\n");
    TEST_ASSERT_EQUAL(1, line_count);
    TEST_ASSERT_EQUAL_STRING("LED_ON:1,2,3", received[0]);
}

void test_empty_lines_are_ignored(void)
{
    reset_line_captures();
    feed("\n\n\n");
    TEST_ASSERT_EQUAL(0, line_count);
}

void test_lone_carriage_returns_are_ignored(void)
{
    reset_line_captures();
    feed("\r\r\r");
    TEST_ASSERT_EQUAL(0, line_count);
}

void test_cr_is_stripped_from_lines(void)
{
    reset_line_captures();
    feed("STATUS\r");
    feed("\n");
    TEST_ASSERT_EQUAL(1, line_count);
    TEST_ASSERT_EQUAL_STRING("STATUS", received[0]);
}

void test_oversized_line_is_truncated_and_flushed(void)
{
    reset_line_captures();
    char big[PROTOCOL_MAX_LINE_LENGTH + 32];
    memset(big, 'A', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    feed(big);
    /* No newline yet: nothing is flushed */
    TEST_ASSERT_EQUAL(0, line_count);
    feed("\n");
    TEST_ASSERT_EQUAL(1, line_count);
    /* Kept at most PROTOCOL_MAX_LINE_LENGTH - 1 bytes */
    TEST_ASSERT_EQUAL(PROTOCOL_MAX_LINE_LENGTH - 1, (int)strlen(received[0]));
    /* The buffer keeps working after the overflow */
    feed("LED_OFF\n");
    TEST_ASSERT_EQUAL(2, line_count);
    TEST_ASSERT_EQUAL_STRING("LED_OFF", received[1]);
}

void test_buffer_reset_discards_partial_line(void)
{
    reset_line_captures();
    feed("PAR");
    protocol_line_buffer_reset(&lb);
    feed("TIAL\n");
    TEST_ASSERT_EQUAL(1, line_count);
    TEST_ASSERT_EQUAL_STRING("TIAL", received[0]);
}

void test_null_arguments_are_ignored(void)
{
    reset_line_captures();
    protocol_line_buffer_feed(NULL, (const uint8_t *)"x", 1, on_line);
    protocol_line_buffer_feed(&lb, NULL, 1, on_line);
    protocol_line_buffer_feed(&lb, (const uint8_t *)"x", 0, on_line);
    TEST_ASSERT_EQUAL(0, line_count);
}

/* ==============================
 * display_text_utf8_decode
 * ============================== */

/* ==============================
 * display_text_utf8_decode
 * ============================== */

void test_utf8_ascii(void)
{
    uint32_t cps[8];
    size_t n = display_text_utf8_decode("ABC", cps, 8);
    TEST_ASSERT_EQUAL(3, n);
    TEST_ASSERT_EQUAL(0x41, cps[0]);
    TEST_ASSERT_EQUAL(0x42, cps[1]);
    TEST_ASSERT_EQUAL(0x43, cps[2]);
}

void test_utf8_two_byte(void)
{
    uint8_t bytes[] = { 0xC3, 0xA9, 0 }; /* "é" */
    uint32_t cps[4];
    size_t n = display_text_utf8_decode((const char *)bytes, cps, 4);
    TEST_ASSERT_EQUAL(1, n);
    TEST_ASSERT_EQUAL(0xE9, cps[0]);
}

void test_utf8_three_byte(void)
{
    uint8_t bytes[] = { 0xE6, 0x97, 0xA5, 0 }; /* "日" */
    uint32_t cps[4];
    size_t n = display_text_utf8_decode((const char *)bytes, cps, 4);
    TEST_ASSERT_EQUAL(1, n);
    TEST_ASSERT_EQUAL(0x65E5, cps[0]);
}

void test_utf8_four_byte_is_one_code_point(void)
{
    /* "🎥" (cinema camera): before the fix each of the four bytes
     * produced a '?'; now the whole sequence is one code point. */
    uint8_t bytes[] = { 0xF0, 0x9F, 0x8E, 0xA5, 0 };
    uint32_t cps[8];
    size_t n = display_text_utf8_decode((const char *)bytes, cps, 8);
    TEST_ASSERT_EQUAL(1, n);
    TEST_ASSERT_EQUAL(0x1F3A5, cps[0]);
}

void test_utf8_invalid_byte_is_question_mark(void)
{
    uint8_t bytes[] = { 0xFF, 0x41, 0 };
    uint32_t cps[4];
    size_t n = display_text_utf8_decode((const char *)bytes, cps, 4);
    TEST_ASSERT_EQUAL(2, n);
    TEST_ASSERT_EQUAL(0x3F, cps[0]); /* '?' */
    TEST_ASSERT_EQUAL(0x41, cps[1]);
}

void test_utf8_truncated_four_byte_is_replaced(void)
{
    uint8_t bytes[] = { 0xF0, 0x9F, 0 }; /* NUL in the middle */
    uint32_t cps[4];
    size_t n = display_text_utf8_decode((const char *)bytes, cps, 4);
    TEST_ASSERT_EQUAL(2, n); /* F0 and the dangling 9F: one '?' each */
    TEST_ASSERT_EQUAL(0x3F, cps[0]);
    TEST_ASSERT_EQUAL(0x3F, cps[1]);
}

void test_utf8_respects_max_out(void)
{
    uint32_t cps[2];
    size_t n = display_text_utf8_decode("ABCD", cps, 2);
    TEST_ASSERT_EQUAL(2, n);
    TEST_ASSERT_EQUAL(0x41, cps[0]);
    TEST_ASSERT_EQUAL(0x42, cps[1]);
}

/* ==============================
 * display_text_layout
 * ============================== */

static size_t to_cps(const char *text, uint32_t *cps, size_t max)
{
    return display_text_utf8_decode(text, cps, max);
}

static display_text_layout_t layout_of(const char *text, int cols, int max_lines)
{
    uint32_t cps[64];
    display_text_layout_t layout;
    size_t len = to_cps(text, cps, 64);
    display_text_layout(cps, len, cols, max_lines, &layout);
    return layout;
}

void test_layout_empty_text(void)
{
    display_text_layout_t layout = layout_of("", 20, 10);
    TEST_ASSERT_EQUAL(0, layout.line_count);
}

void test_layout_short_word_single_line(void)
{
    display_text_layout_t layout = layout_of("hi", 20, 10);
    TEST_ASSERT_EQUAL(1, layout.line_count);
    TEST_ASSERT_EQUAL(0, layout.line_start[0]);
    TEST_ASSERT_EQUAL(2, layout.line_len[0]);
}

void test_layout_word_wrap_on_space(void)
{
    /* 5 columns: "aaaaa bb" -> "aaaaa" / "bb" */
    display_text_layout_t layout = layout_of("aaaaa bb", 5, 10);
    TEST_ASSERT_EQUAL(2, layout.line_count);
    TEST_ASSERT_EQUAL(0, layout.line_start[0]);
    TEST_ASSERT_EQUAL(5, layout.line_len[0]);
    TEST_ASSERT_EQUAL(6, layout.line_start[1]);
    TEST_ASSERT_EQUAL(2, layout.line_len[1]);
}

void test_layout_explicit_newline_breaks_lines(void)
{
    display_text_layout_t layout = layout_of("ab\ncd", 20, 10);
    TEST_ASSERT_EQUAL(2, layout.line_count);
    TEST_ASSERT_EQUAL(0, layout.line_start[0]);
    TEST_ASSERT_EQUAL(2, layout.line_len[0]);
    TEST_ASSERT_EQUAL(3, layout.line_start[1]);
    TEST_ASSERT_EQUAL(2, layout.line_len[1]);
}

void test_layout_trailing_newline_adds_no_line(void)
{
    display_text_layout_t layout = layout_of("ab\n", 20, 10);
    TEST_ASSERT_EQUAL(1, layout.line_count);
    TEST_ASSERT_EQUAL(2, layout.line_len[0]);
}

void test_layout_double_newline_yields_blank_line(void)
{
    display_text_layout_t layout = layout_of("ab\n\ncd", 20, 10);
    TEST_ASSERT_EQUAL(3, layout.line_count);
    TEST_ASSERT_EQUAL(2, layout.line_len[0]);
    TEST_ASSERT_EQUAL(0, layout.line_len[1]); /* blank */
    TEST_ASSERT_EQUAL(2, layout.line_len[2]);
}

void test_layout_hard_splits_oversized_word(void)
{
    /* 30 'a' on a 20-column screen -> 20 + 10 */
    display_text_layout_t layout = layout_of(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 20, 10);
    TEST_ASSERT_EQUAL(2, layout.line_count);
    TEST_ASSERT_EQUAL(0, layout.line_start[0]);
    TEST_ASSERT_EQUAL(20, layout.line_len[0]);
    TEST_ASSERT_EQUAL(20, layout.line_start[1]);
    TEST_ASSERT_EQUAL(10, layout.line_len[1]);
}

void test_layout_stops_at_line_budget(void)
{
    /* 1 column: one word per line, at most 3 lines kept */
    display_text_layout_t layout = layout_of("a b c d", 1, 3);
    TEST_ASSERT_EQUAL(3, layout.line_count);
    for (int i = 0; i < 3; i++) {
        TEST_ASSERT_EQUAL(1, layout.line_len[i]);
    }
}

void test_layout_multibyte_text_wraps_per_code_point(void)
{
    /* "日本語" is three code points (9 UTF-8 bytes); a 2-column screen
     * must wrap by code point, not by byte. */
    display_text_layout_t layout = layout_of("\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E", 2, 10);
    TEST_ASSERT_EQUAL(2, layout.line_count);
    TEST_ASSERT_EQUAL(0, layout.line_start[0]);
    TEST_ASSERT_EQUAL(2, layout.line_len[0]);
    TEST_ASSERT_EQUAL(2, layout.line_start[1]);
    TEST_ASSERT_EQUAL(1, layout.line_len[1]);
}

int main(void)
{
    UNITY_BEGIN();

    RUN_TEST(test_bare_led_on_uses_default_color);
    RUN_TEST(test_led_on_with_color);
    RUN_TEST(test_led_on_with_zero_color);
    RUN_TEST(test_led_on_color_out_of_range_is_invalid);
    RUN_TEST(test_led_on_color_incomplete_is_invalid);
    RUN_TEST(test_led_on_color_trailing_junk_is_invalid);
    RUN_TEST(test_led_on_negative_component_is_invalid);
    RUN_TEST(test_led_off);
    RUN_TEST(test_blink_fast);
    RUN_TEST(test_blink_slow);
    RUN_TEST(test_status);
    RUN_TEST(test_scene);
    RUN_TEST(test_scene_with_spaces_and_utf8);
    RUN_TEST(test_empty_scene_clears_the_display);
    RUN_TEST(test_auth_with_secret);
    RUN_TEST(test_auth_empty_is_invalid);
    RUN_TEST(test_unknown_command);
    RUN_TEST(test_commands_are_case_sensitive);
    RUN_TEST(test_empty_line_is_unknown);

    RUN_TEST(test_single_line);
    RUN_TEST(test_two_lines_in_one_chunk);
    RUN_TEST(test_line_split_across_chunks);
    RUN_TEST(test_empty_lines_are_ignored);
    RUN_TEST(test_lone_carriage_returns_are_ignored);
    RUN_TEST(test_cr_is_stripped_from_lines);
    RUN_TEST(test_oversized_line_is_truncated_and_flushed);
    RUN_TEST(test_buffer_reset_discards_partial_line);
    RUN_TEST(test_null_arguments_are_ignored);

    RUN_TEST(test_utf8_ascii);
    RUN_TEST(test_utf8_two_byte);
    RUN_TEST(test_utf8_three_byte);
    RUN_TEST(test_utf8_four_byte_is_one_code_point);
    RUN_TEST(test_utf8_invalid_byte_is_question_mark);
    RUN_TEST(test_utf8_truncated_four_byte_is_replaced);
    RUN_TEST(test_utf8_respects_max_out);
    RUN_TEST(test_layout_empty_text);
    RUN_TEST(test_layout_short_word_single_line);
    RUN_TEST(test_layout_word_wrap_on_space);
    RUN_TEST(test_layout_explicit_newline_breaks_lines);
    RUN_TEST(test_layout_trailing_newline_adds_no_line);
    RUN_TEST(test_layout_double_newline_yields_blank_line);
    RUN_TEST(test_layout_hard_splits_oversized_word);
    RUN_TEST(test_layout_stops_at_line_budget);
    RUN_TEST(test_layout_multibyte_text_wraps_per_code_point);

    return UNITY_END();
}
