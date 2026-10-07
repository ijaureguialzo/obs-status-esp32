/**
 * @file test_protocol.c
 * @brief Host-side unit tests for the dependency-free protocol modules:
 *        - protocol_message: text command parsing
 *        - protocol_line_buffer: byte stream line assembly
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

#include <string.h>

#include "../src/protocol/protocol_message.c"
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

    return UNITY_END();
}
