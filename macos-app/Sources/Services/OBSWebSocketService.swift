//
//  OBSWebSocketService.swift
//  WebSocket client for OBS Studio obs-websocket API
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol OBSWebSocketServiceProtocol {
    var isConnected: Bool { get }
    var recordingState: RecordingState { get }
    var recordingStateStream: AsyncStream<RecordingState> { get }
    
    func connect(host: String, port: Int, token: String) async throws
    func disconnect()
}

class OBSWebSocketService: @unchecked Sendable, OBSWebSocketServiceProtocol {
    private var websocketTask: Task<Void, Error>?
    private var continuation: AsyncStream<RecordingState>.Continuation?
    private var wsURL: URL?
    private var currentRecordingState: RecordingState = .unknown
    private var isConnectedFlag: Bool = false
    
    var isConnected: Bool {
        isConnectedFlag
    }
    
    var recordingState: RecordingState {
        currentRecordingState
    }
    
    var recordingStateStream: AsyncStream<RecordingState> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    func connect(host: String, port: Int, token: String) async throws {
        guard !isConnected else { return }
        
        let url = URL(string: "ws://\(host):\(port)")!
        wsURL = url
        
        let websocket = WebSocket(url: url)
        
        // Send auth request if token is provided
        if !token.isEmpty {
            let authRequest = ObsWebSocketRequest(
                eventID: 1,
                requestType: "AuthRequired",
                requestData: [:]
            )
            // Token will be sent after connection is established
        }
        
        websocketTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Connection loop with reconnection
            var reconnectDelay: Double = 1.0
            let maxReconnectDelay: Double = 30.0
            
            while self.isConnectedFlag || (self.wsURL != nil) {
                do {
                    try await self.establishConnection(url: url, token: token)
                    reconnectDelay = 1.0 // Reset on success
                } catch {
                    if self.wsURL == nil { break } // Intentional disconnect
                    
                    Task {
                        await self.continuation?.yield(.unknown)
                    }
                    
                    reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
                    try await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
                }
            }
        }
    }
    
    private func establishConnection(url: URL, token: String) async throws {
        // WebSocket connection implementation using Foundation
        // This is a placeholder - in production, use a proper WebSocket library
        
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OBSWebSocketError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        isConnectedFlag = true
        
        // Read events and dispatch recording state changes
        for try await line in bytes.lines {
            if let event = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any] {
                if let eventData = event["eventData"] as? [String: Any],
                   let recording = eventData["recording"] as? Bool {
                    currentRecordingState = recording ? .recording : .notRecording
                    continuation?.yield(currentRecordingState)
                }
            }
        }
    }
    
    func disconnect() {
        wsURL = nil
        isConnectedFlag = false
        websocketTask?.cancel()
        websocketTask = nil
        currentRecordingState = .unknown
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - Supporting Types

private struct ObsWebSocketRequest: Codable {
    let eventID: Int
    let requestType: String
    let requestData: [String: Any]
}

private struct WebSocket {
    let url: URL
    
    // Placeholder WebSocket implementation
    // In production, integrate with a proper WebSocket library
    // (e.g., Starscream, SwiftWebSocket, or custom socket implementation)
}
