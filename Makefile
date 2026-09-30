.DEFAULT_GOAL := help

PIO ?= pio
SWIFT ?= swift

.PHONY: all firmware install macos help

all: firmware macos

firmware:
	$(PIO) run -d esp32-firmware

install: firmware
	$(PIO) run -d esp32-firmware -t upload

macos:
	$(SWIFT) build --package-path macos-app

help:
	@printf '%s\n' \
		'Targets:' \
		'  make           Build the ESP32 firmware and macOS app.' \
		'  make firmware  Build the ESP32 firmware.' \
		'  make install   Upload the ESP32 firmware to the connected board.' \
		'  make macos     Build the macOS app.'
