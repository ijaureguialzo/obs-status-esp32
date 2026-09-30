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
}

/// Parsed status response from ESP32.
/// Format: "STATUS:LED=<state>|USB=<state>|ERROR=<code>"
struct ObsStatusResponse: Codable {
    let led: String
    let usb: String
    let errorCode: Int
    
    init?(from rawResponse: String) {
        // Format: "STATUS:LED=<state>|USB=<state>|ERROR=<code>"
        guard rawResponse.hasPrefix("STATUS:") else { return nil }
        
        let content = String(rawResponse.dropFirst(7)) // Remove "STATUS:"
        let parts = content.split(separator: "|")
        
        guard parts.count == 3 else { return nil }
        
        // Parse LED state
        guard parts[0].hasPrefix("LED=") else { return nil }
        led = String(parts[0].dropFirst(4))
        
        // Parse USB state
        guard parts[1].hasPrefix("USB=") else { return nil }
        usb = String(parts[1].dropFirst(4))
        
        // Parse error code
        guard parts[2].hasPrefix("ERROR=") else { return nil }
        errorCode = Int(String(parts[2].dropFirst(6))) ?? 0
    }
}

/// Utility functions for protocol handling
enum ObsProtocolUtil {
    /// Check if a response indicates an error
    static func isErrorResponse(_ response: String) -> Bool {
        response.hasPrefix("ERROR:")
    }
}