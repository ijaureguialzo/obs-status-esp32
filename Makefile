.DEFAULT_GOAL := help

PIO ?= pio
SWIFT ?= swift

# Firmware environment to build/upload. Supported values:
#   esp32-s3-dev-kit-n8r8      ESP32-S3 dev board with onboard RGB LED (default)
#   esp32-c6-touch-lcd-1_47    Waveshare ESP32-C6-Touch-LCD-1.47 (touch LCD)
BOARD ?= esp32-s3-dev-kit-n8r8

.PHONY: all firmware firmware-s3 firmware-c6 install install-s3 install-c6 macos help

all: firmware macos

firmware:
	$(PIO) run -d esp32-firmware -e $(BOARD)

firmware-s3:
	$(PIO) run -d esp32-firmware -e esp32-s3-dev-kit-n8r8

firmware-c6:
	$(PIO) run -d esp32-firmware -e esp32-c6-touch-lcd-1_47

install: firmware
	$(PIO) run -d esp32-firmware -e $(BOARD) -t upload

install-s3:
	$(PIO) run -d esp32-firmware -e esp32-s3-dev-kit-n8r8 -t upload

install-c6:
	$(PIO) run -d esp32-firmware -e esp32-c6-touch-lcd-1_47 -t upload

monitor:
	$(PIO) device monitor

macos:
	$(SWIFT) build --package-path macos-app

help:
	@printf '%s\n' \
		'Targets:' \
		'  make             Build the ESP32 firmware and macOS app.' \
		'  make firmware    Build the firmware for BOARD (default: esp32-s3-dev-kit-n8r8).' \
		'  make install     Upload the firmware for BOARD to the connected board.' \
		'  make macos       Build the macOS app.' \
		'  make monitor     Show serial console.' \
		'' \
		'Board shortcuts:' \
		'  make firmware-s3 / install-s3  ESP32-S3-DevKit N8R8 (LED only).' \
		'  make firmware-c6 / install-c6  Waveshare ESP32-C6-Touch-LCD-1.47 (touch LCD).' \
		'' \
		'Or pick the board explicitly:' \
		'  make install BOARD=esp32-c6-touch-lcd-1_47'
