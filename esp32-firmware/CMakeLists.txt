cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(obs-status-esp32)

# Add custom source files
idf_component_register(
    SRCS 
        src/main.c
        src/usb/usb_cdc.c
        src/led/led_controller.c
        src/protocol/protocol_parser.c
    INCLUDE_DIRS 
        include
    REQUIRES 
        driver 
        nvs_flash
        usb
)
