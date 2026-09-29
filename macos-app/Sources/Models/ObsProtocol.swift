//
//  ObsProtocol.swift
//  Protocol definitions for macOS <-> ESP32 communication
//

import Foundation

/// Text-based commands sent from macOS app to ESP32 over USB CDC
enum ObsCommand: String, CaseIterable {
    case ledOn = "LED_ON"
    case ledOff = "LED_OFF"
    case blinkFast = "BLINK_FAST"
    case blinkSlow = "BLINK_SLOW"
    case status = "STATUS"
    
    var rawValue: String {
        self.rawValue
    }
    
    var lineTerminated: String {
        "\(rawValue)\n"
    }
}

/// Responses from ESP32 back to macOS app
enum ObsResponse: String {
    case ok = "OK"
    case unknownCommand = "ERROR: UNKNOWN_COMMAND"
    case invalidFormat = "ERROR: INVALID_FORMAT"
}

/// Parsed status response from ESP32
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
    /// Parse incoming line and return the corresponding command (or nil if unknown)
    static func parseCommand(_ line: String) -> ObsCommand? {
        guard !line.isEmpty else { return nil }
        return ObsCommand(rawValue: line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    /// Format a command as a line-terminated string for transmission
    static func formatCommand(_ command: ObsCommand) -> String {
        command.lineTerminated
    }
    
    /// Check if a response indicates an error
    static func isErrorResponse(_ response: String) -> Bool {
        response.hasPrefix("ERROR:")
    }
}
