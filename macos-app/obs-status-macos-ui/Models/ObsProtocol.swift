//
//  ObsProtocol.swift
//  Protocol definitions for macOS <-> ESP32 communication.
//  Text-based protocol sent over USB CDC serial.
//

import Foundation

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
}

/// Parsed status response from ESP32.
/// Format: "STATUS:LED=<state>|OBS=<state>|ERROR=<code>"
struct ObsStatusResponse: Codable {
    let led: String
    let obs: String
    let errorCode: Int
    
    init?(from rawResponse: String) {
        // Format: "STATUS:LED=<state>|OBS=<state>|ERROR=<code>"
        guard rawResponse.hasPrefix("STATUS:") else { return nil }
        
        let content = String(rawResponse.dropFirst(7)) // Remove "STATUS:"
        let parts = content.split(separator: "|")
        
        guard parts.count == 3 else { return nil }
        
        // Parse LED state
        guard parts[0].hasPrefix("LED=") else { return nil }
        led = String(parts[0].dropFirst(4))
        
        // Parse OBS state
        guard parts[1].hasPrefix("OBS=") else { return nil }
        obs = String(parts[1].dropFirst(4))
        
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