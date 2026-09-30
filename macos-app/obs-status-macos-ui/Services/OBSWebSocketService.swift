//
//  OBSWebSocketService.swift
//  OBS Studio obs-websocket v5 client.
//

import CryptoKit
import Foundation

enum OBSWebSocketError: LocalizedError {
    case invalidURL
    case unexpectedMessage
    case authenticationFailed
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OBS WebSocket address"
        case .unexpectedMessage:
            return "OBS sent an unexpected WebSocket message"
        case .authenticationFailed:
            return "OBS rejected the authentication token"
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
protocol OBSWebSocketServiceProtocol: AnyObject {
    var isConnected: Bool { get }
    var isReconnecting: Bool { get }
    var recordingState: RecordingState { get }
    var recordingStateStream: AsyncStream<RecordingState> { get }
    func connect(host: String, port: Int, token: String) async throws
    func disconnect()
}

@MainActor
final class OBSWebSocketService: OBSWebSocketServiceProtocol {
    private var session: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<RecordingState>.Continuation] = [:]
    private var connectionHost: String?
    private var connectionPort: Int?
    private var connectionToken = ""
    private(set) var isConnected = false
    private(set) var isReconnecting = false
    private(set) var recordingState: RecordingState = .unknown

    var recordingStateStream: AsyncStream<RecordingState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(recordingState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func connect(host: String, port: Int, token: String) async throws {
        guard !isConnected else { return }
        connectionHost = host
        connectionPort = port
        connectionToken = token
        isReconnecting = false
        do {
            try await establishConnection()
            receiveTask = Task { [weak self] in
                await self?.receiveMessages()
            }
        } catch {
            closeTransport()
            connectionHost = nil
            connectionPort = nil
            throw error
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connectionHost = nil
        connectionPort = nil
        connectionToken = ""
        isReconnecting = false
        closeTransport()
        setRecordingState(.unknown)
    }

    private func establishConnection() async throws {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = connectionHost
        components.port = connectionPort
        guard let url = components.url else {
            throw OBSWebSocketError.invalidURL
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        let newSession = URLSession(configuration: configuration)
        let newWebSocket = newSession.webSocketTask(with: url)
        session = newSession
        webSocket = newWebSocket
        newWebSocket.resume()

        do {
            let greeting = try await receiveJSON(from: newWebSocket)
            guard greeting["op"] as? Int == 0,
                  let data = greeting["d"] as? [String: Any],
                  let rpcVersion = data["rpcVersion"] as? Int else {
                throw OBSWebSocketError.unexpectedMessage
            }

            var identifyData: [String: Any] = [
                "rpcVersion": rpcVersion,
                "eventSubscriptions": 0x3FF,
            ]
            if let authentication = data["authentication"] as? [String: Any],
               let salt = authentication["salt"] as? String,
               let challenge = authentication["challenge"] as? String {
                guard !connectionToken.isEmpty else {
                    throw OBSWebSocketError.authenticationFailed
                }
                identifyData["authentication"] = Self.authentication(
                    password: connectionToken,
                    salt: salt,
                    challenge: challenge
                )
            }
            try await sendJSON(["op": 1, "d": identifyData], to: newWebSocket)

            let identified = try await receiveJSON(from: newWebSocket)
            guard identified["op"] as? Int == 2 else {
                throw OBSWebSocketError.authenticationFailed
            }

            isConnected = true
            isReconnecting = false
            setRecordingState(.unknown)
            try await sendJSON([
                "op": 6,
                "d": [
                    "requestType": "GetRecordStatus",
                    "requestId": UUID().uuidString,
                ],
            ], to: newWebSocket)
        } catch {
            closeTransport()
            throw error
        }
    }

    private func receiveMessages() async {
        var retryDelay = 1
        while !Task.isCancelled {
            do {
                guard let webSocket else { throw OBSWebSocketError.unexpectedMessage }
                let message = try await receiveJSON(from: webSocket)
                if message["op"] as? Int == 3 {
                    try await sendJSON(["op": 4, "d": message["d"] ?? [:]], to: webSocket)
                    continue
                }
                if message["op"] as? Int == 7,
                   let data = message["d"] as? [String: Any],
                   data["requestType"] as? String == "GetRecordStatus",
                   let responseData = data["responseData"] as? [String: Any],
                   let active = responseData["outputActive"] as? Bool {
                    let paused = responseData["outputPaused"] as? Bool ?? false
                    setRecordingState(active && !paused ? .recording : .notRecording)
                    continue
                }
                guard message["op"] as? Int == 5,
                      let data = message["d"] as? [String: Any],
                      let eventType = data["eventType"] as? String,
                      let eventData = data["eventData"] as? [String: Any] else {
                    continue
                }
                if eventType == "RecordStateChanged" {
                    setRecordingState(Self.recordingState(from: eventData))
                }
            } catch {
                guard !Task.isCancelled else { return }
                isConnected = false
                isReconnecting = true
                setRecordingState(.unknown)
                closeTransport()

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(retryDelay))
                        guard connectionHost != nil else { return }
                        try await establishConnection()
                        retryDelay = 1
                        break
                    } catch {
                        guard !Task.isCancelled else { return }
                        retryDelay = min(retryDelay * 2, 30)
                    }
                }
            }
        }
    }

    private func receiveJSON(from webSocket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await webSocket.receive()
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let bytes):
            data = bytes
        @unknown default:
            throw OBSWebSocketError.unexpectedMessage
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OBSWebSocketError.unexpectedMessage
        }
        if json["op"] as? Int == 9 {
            throw OBSWebSocketError.requestFailed("OBS closed the WebSocket connection")
        }
        if json["op"] as? Int == 7,
           let response = json["d"] as? [String: Any],
           let responseData = response["responseData"] as? [String: Any],
           let outputActive = responseData["outputActive"] as? Bool {
            let outputPaused = responseData["outputPaused"] as? Bool ?? false
            setRecordingState(outputActive && !outputPaused ? .recording : .notRecording)
        }
        return json
    }

    /// Maps a RecordStateChanged event payload to a recording state.
    /// `outputActive` stays true while paused, so `outputState` is authoritative.
    private static func recordingState(from eventData: [String: Any]) -> RecordingState {
        guard let outputState = eventData["outputState"] as? String else {
            return (eventData["outputActive"] as? Bool ?? false) ? .recording : .notRecording
        }
        switch outputState {
        case "OBS_WEBSOCKET_OUTPUT_STARTED", "OBS_WEBSOCKET_OUTPUT_RESUMED":
            return .recording
        case "OBS_WEBSOCKET_OUTPUT_STOPPED", "OBS_WEBSOCKET_OUTPUT_PAUSED":
            return .notRecording
        default:
            return .unknown
        }
    }

    private func sendJSON(_ json: [String: Any], to webSocket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OBSWebSocketError.unexpectedMessage
        }
        try await webSocket.send(.string(text))
    }

    private func closeTransport() {
        isConnected = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func setRecordingState(_ state: RecordingState) {
        recordingState = state
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
}
