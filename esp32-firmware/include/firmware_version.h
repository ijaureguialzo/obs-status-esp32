/**
 * @file firmware_version.h
 * @brief Firmware version and build number
 *
 * The values come from firmware_version_generated.h, which is generated
 * from version.txt at the project root
 * (scripts/generate_version.sh, run by the CMake build, the PlatformIO
 * extra script, and friends). The generated header is git-ignored and is
 * (re)created by the build; the generator falls back to 1.0.0 / build 1
 * for fresh checkouts / CI.
 */
#ifndef FIRMWARE_VERSION_H
#define FIRMWARE_VERSION_H

#include "firmware_version_generated.h"

/* "1.0.0 (1)" */
#define FIRMWARE_VERSION_WITH_BUILD FIRMWARE_VERSION " (" FIRMWARE_BUILD ")"

#endif /* FIRMWARE_VERSION_H */
