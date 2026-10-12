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

#if __has_include("firmware_version_generated.h")
#include "firmware_version_generated.h"
#else
/* The generated header is missing (e.g. the build never ran the version
 * generator); fall back to an explicit default so the build still works.
 * generate_version.sh uses the same values for its own fallback. */
#define FIRMWARE_VERSION "1.0.0"
#define FIRMWARE_BUILD "1"
#endif

/* "1.0.0 (1)" */
#define FIRMWARE_VERSION_WITH_BUILD FIRMWARE_VERSION " (" FIRMWARE_BUILD ")"

#endif /* FIRMWARE_VERSION_H */
