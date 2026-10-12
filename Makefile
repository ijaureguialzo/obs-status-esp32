.DEFAULT_GOAL := help

PIO ?= pio
SWIFT ?= swift
XCODEBUILD ?= xcodebuild

# Name of the macOS app bundle (Xcode PRODUCT_NAME)
APP_NAME ?= OBS Status

# Firmware environment to build/upload. Supported values:
#   esp32-s3-dev-kit-n8r8      ESP32-S3 dev board with onboard RGB LED (default)
#   esp32-c6-touch-lcd-1_47    Waveshare ESP32-C6-Touch-LCD-1.47 (touch LCD)
BOARD ?= esp32-s3-dev-kit-n8r8

.PHONY: all firmware firmware-s3 firmware-c6 firmware-debug install install-s3 install-c6 monitor macos macos-release install-macos check test check-all help

all: firmware macos

firmware:
	$(PIO) run -d esp32-firmware -e $(BOARD)

firmware-debug:
	$(PIO) run -d esp32-firmware -e esp32-c6-touch-lcd-1_47-debug

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

# Verification targets (the same checks CI runs, minus the macOS-specific
# ones that need Xcode). `check` is the fast loop; `check-all` adds the
# slower full firmware builds.
check:
	bash scripts/check_protocol_sync.sh
	$(PIO) test -d esp32-firmware -e host-tests
	$(SWIFT) test --package-path macos-app

test: check

check-all: check
	$(PIO) run -d esp32-firmware -e esp32-s3-dev-kit-n8r8
	$(PIO) run -d esp32-firmware -e esp32-c6-touch-lcd-1_47
	cd macos-app && $(XCODEBUILD) -scheme obs-status-macos-ui -configuration Debug build

macos-release:
	cd macos-app && $(XCODEBUILD) -scheme obs-status-macos-ui -configuration Release build -derivedDataPath .derived

install-macos: macos-release
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "macos-app/.derived/Build/Products/Release/$(APP_NAME).app" "/Applications/$(APP_NAME).app"

help:
	@printf '%s\n' \
		'Targets:' \
		'  make             Build the ESP32 firmware and macOS app.' \
		'  make firmware    Build the firmware for BOARD (default: esp32-s3-dev-kit-n8r8).' \
		'  make install     Upload the firmware for BOARD to the connected board.' \
		'  make macos           Build the macOS app (debug, via swift build).' \
		'  make macos-release  Build the macOS app as a Release .app bundle.' \
		'  make install-macos  Build Release and install it in /Applications.' \
		'  make monitor     Show serial console.' \
		'  make check       Protocol sync + firmware host tests + Swift tests.' \
		'  make check-all   check + full firmware builds + Xcode build.' \
		'' \
		'Board shortcuts:' \
		'  make firmware-s3 / install-s3  ESP32-S3-DevKit N8R8 (LED only).' \
		'  make firmware-c6 / install-c6  Waveshare ESP32-C6-Touch-LCD-1.47 (touch LCD).' \
		'' \
		'Or pick the board explicitly:' \
		'  make install BOARD=esp32-c6-touch-lcd-1_47'
