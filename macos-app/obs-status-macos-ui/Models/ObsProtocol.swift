//
//  ObsProtocol.swift
//  Protocol definitions for macOS <-> ESP32 communication.
//  Text-based protocol sent over USB CDC serial.
//

import AppKit
import Foundation
import SwiftUI

struct LEDColor: Codable, Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let recordingDefault = LEDColor(red: 0, green: 255, blue: 0)

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
        self.init(
            red: UInt8((red * 255).rounded()),
            green: UInt8((green * 255).rounded()),
            blue: UInt8((blue * 255).rounded())
        )
    }

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

/// Text-based commands sent from macOS app to ESP32 over USB CDC
enum ObsCommand: String, CaseIterable {
    case ledOn = "LED_ON"
    case ledOff = "LED_OFF"
    case blinkFast = "BLINK_FAST"
    case blinkSlow = "BLINK_SLOW"
    case status = "STATUS"

    var lineTerminated: String {
        "\(rawValue)\n"
    }

    static func ledOn(color: LEDColor) -> String {
        "LED_ON:\(color.red),\(color.green),\(color.blue)\n"
    }

    /// Tells the ESP32 which OBS scene is active so boards with a display
    /// can show its name. Newlines and carriage returns are stripped and the
    /// name is truncated to fit both firmware limits deterministically:
    /// 95 characters (`s_scene[96]` including NUL) and 121 UTF-8 bytes
    /// (`SCENE:` + name must fit the 127-byte protocol line); the byte cut
    /// backs off to a character boundary. The firmware would otherwise keep
    /// only the first 127 bytes of an oversized line.
    static func scene(name: String) -> String {
        let sanitized =
            name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var utf8 = Array(sanitized.prefix(95).utf8)
        if utf8.count > 121 {
            utf8.removeLast(utf8.count - 121)
            while let last = utf8.last {
                if last < 0x80 {
                    break  // complete ASCII byte
                }
                utf8.removeLast()
                if last & 0xC0 != 0x80 {
                    break  // removed the lead byte of a split character
                }
            }
        }
        return "SCENE:\(String(decoding: utf8, as: UTF8.self))\n"
    }

    /// Proves the host knows the device's shared secret (shown by the board
    /// on first pairing). The device answers `OK` or `ERROR: AUTH_FAILED`.
    static func auth(secret: String) -> String {
        "AUTH:\(secret)\n"
    }
}

/// Unsolicited events sent from the ESP32 to the macOS app.
/// Every event line starts with the `EVENT:` prefix.
enum ObsEvent: String {
    /// The user tapped the touch screen; pause/resume the OBS recording.
    case togglePause = "EVENT:TOGGLE_PAUSE"

    /// Prefix shared by every event line; used to route incoming lines.
    static let linePrefix = "EVENT:"

    static func parse(_ line: String) -> ObsEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return ObsEvent(rawValue: trimmed)
    }
}

/// Well-formed command responses, mirroring protocol/obs_protocol.h.
///
/// These strings are the single in-Swift copy of the protocol's response
/// vocabulary; a CI check (scripts/check_protocol_sync.sh) verifies that
/// every literal defined in the C header exists here.
enum ObsResponse {
    static let ok = "OK"
    static let errorPrefix = "ERROR:"
    static let errorUnknown = "ERROR: UNKNOWN_COMMAND"
    static let errorInvalidFormat = "ERROR: INVALID_FORMAT"
    static let errorAuth = "ERROR: AUTH_FAILED"
    static let statusPrefix = "STATUS:"
    /// The `|AUTH=1` suffix advertised by current firmware in the STATUS
    /// response: the device understands the AUTH command.
    static let statusAuthSupported = "|AUTH=1"

    /// Whether a line read from the serial port is a command response
    /// (anything else is firmware log output and gets dropped).
    static func isResponse(_ line: String) -> Bool {
        line == ok || line.hasPrefix(errorPrefix) || line.hasPrefix(statusPrefix)
    }

    /// Whether a completed response reports an error.
    static func isErrorResponse(_ response: String) -> Bool {
        response.hasPrefix(errorPrefix)
    }
}

/// Utility functions for protocol handling
enum ObsProtocolUtil {
    /// Check if a response indicates an error
    static func isErrorResponse(_ response: String) -> Bool {
        ObsResponse.isErrorResponse(response)
    }
}
