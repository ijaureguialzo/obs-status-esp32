idf_component_register(
    SRCS
        main.c
        usb/usb_cdc.c
        led/led_controller.c
        display/display_controller.c
        touch/touch_controller.c
        board/board_i2c.c
        imu/imu_qmi8658.c
        protocol/protocol_parser.c
        protocol/protocol_message.c
        protocol/protocol_line_buffer.c
    INCLUDE_DIRS
        ../include
        ../../protocol
    REQUIRES
        driver
        nvs_flash
        esp_rom
        esp_lcd
        esp_driver_rmt
        esp_driver_usb_serial_jtag
        esp_driver_spi
        esp_driver_i2c
        esp_driver_ledc
        esp_driver_gpio
        esp_lcd_jd9853
        esp_lcd_touch_axs5106
        espressif__esp_lcd_touch
)

# Version / build number from the git-ignored version.txt at the project
# root (line 1: version, line 2: build number). The values land in
# include/firmware_version_generated.h, which is git-ignored and
# (re)generated in place by scripts/generate_version.sh with fallback
# values (1.0.0 / build 1) when version.txt is absent (fresh clones / CI);
# sources pick them up through #include "firmware_version.h". PlatformIO's
# SCons-driven build never runs ninja, so esp32-firmware/scripts/buildinfo.py
# (extra script) performs the same regeneration for `pio run`.
set(OBS_STATUS_VERSION_HEADER ${CMAKE_CURRENT_SOURCE_DIR}/../include/firmware_version_generated.h)

set(OBS_STATUS_VERSION_DEPS ${CMAKE_SOURCE_DIR}/../scripts/generate_version.sh)
if(EXISTS ${CMAKE_SOURCE_DIR}/../version.txt)
    list(APPEND OBS_STATUS_VERSION_DEPS ${CMAKE_SOURCE_DIR}/../version.txt)
endif()

# Bootstrap the header at configure time in case it was deleted.
if(NOT EXISTS ${OBS_STATUS_VERSION_HEADER})
    execute_process(
        COMMAND sh ${CMAKE_SOURCE_DIR}/../scripts/generate_version.sh c ${OBS_STATUS_VERSION_HEADER}
        RESULT_VARIABLE OBS_STATUS_GEN_RESULT)
    if(NOT OBS_STATUS_GEN_RESULT EQUAL 0)
        message(WARNING "generate_version.sh failed; keeping the previous firmware version header")
    endif()
endif()

add_custom_command(
    OUTPUT ${OBS_STATUS_VERSION_HEADER}
    COMMAND sh ${CMAKE_SOURCE_DIR}/../scripts/generate_version.sh c ${OBS_STATUS_VERSION_HEADER}
    DEPENDS ${OBS_STATUS_VERSION_DEPS}
    COMMENT "Generating firmware version header from version.txt"
    VERBATIM
)
add_custom_target(firmware_version_header DEPENDS ${OBS_STATUS_VERSION_HEADER})
add_dependencies(${COMPONENT_LIB} firmware_version_header)
