/**
 * @file protocol_parser.h
 * @brief Command parser for the text-based protocol
 * 
 * Parses incoming text commands from the macOS application
 * and dispatches them to the appropriate handler (LED control).
 */

#ifndef PROTOCOL_PARSER_H
#define PROTOCOL_PARSER_H

#include <esp_err.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Maximum length of a command line
 */
#define PROTOCOL_MAX_LINE_LENGTH 128

/**
 * @brief Process an incoming command line
 * @param line Null-terminated command string (without newline)
 * @return ESP_OK on success, ESP_ERR_NOT_FOUND for unknown commands
 */
esp_err_t protocol_process(const char *line);

/**
 * @brief Initialize the protocol parser
 * @return ESP_OK on success
 */
esp_err_t protocol_init(void);

/**
 * @brief Emit the EVENT:TOGGLE_PAUSE line towards the host
 *
 * Called by the touch controller when the user taps the screen. The macOS
 * app reacts by pausing/resuming the OBS recording. Safe to call on boards
 * without a display; the event is simply sent over USB CDC.
 */
void protocol_notify_toggle_pause(void);

#ifdef __cplusplus
}
#endif

#endif /* PROTOCOL_PARSER_H */
