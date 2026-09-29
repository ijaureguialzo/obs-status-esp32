//
//  OBSWebSocketService.swift
//  WebSocket client for OBS Studio obs-websocket API
//  Implements a complete WebSocket client using Foundation and CryptoKit.
//

import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum OBSWebSocketError: LocalizedError {
    case connectionFailed(String)
    case handshakeFailed(String)
    case messageParseFailed(String)
    case connectionLost
    case writeFailed
    case readFailed
    case tokenDenied
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .handshakeFailed(let msg):
            return "WebSocket handshake failed: \(msg)"
        case .messageParseFailed(let msg):
            return "Failed to parse message: \(msg)"
        case .connectionLost:
            return "WebSocket connection was lost"
        case .writeFailed:
            return "Failed to send data over WebSocket"
        case .readFailed:
            return "Failed to receive data from WebSocket"
        case .tokenDenied:
            return "OBS rejected authentication token"
        }
    }
}

protocol OBSWebSocketServiceProtocol: Sendable {
    var isConnected: Bool { get }
    var recordingState: RecordingState { get }
    var recordingStateStream: AsyncStream<RecordingState> { get }
    func connect(host: String, port: Int, token: String) async throws
    func disconnect()
}

class OBSWebSocketService: @unchecked Sendable, OBSWebSocketServiceProtocol {
    // MARK: - Properties
    
    private var socketFD: Int32 = -1
    private var isConnectedFlag: Bool = false
    private var currentRecordingState: RecordingState = .unknown
    private var continuation: AsyncStream<RecordingState>.Continuation?
    
    // Connection state
    private var host: String?
    private var port: Int?
    private var token: String?
    
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
    
    // MARK: - Public API
    
    func connect(host: String, port: Int, token: String) async throws {
        guard !isConnected else { return }
        
        self.host = host
        self.port = port
        self.token = token
        
        do {
            try await performHandshake(host: host, port: port)
            isConnectedFlag = true
            
            // Start background task for receiving events
            startReceivingEvents()
            
        } catch {
            closeSocket()
            throw error
        }
    }
    
    func disconnect() {
        host = nil
        port = nil
        token = nil
        isConnectedFlag = false
        closeSocket()
        currentRecordingState = .unknown
        continuation?.finish()
        continuation = nil
    }
    
    func sendAuthRequest() async throws {
        guard !token.isEmpty else { return }
        
        let authMessage = """
        {"eventID":1,"data":{"requestType":"Authenticate","requestData":{"auth":"\(token)"}}}
        """
        let data = Array(authMessage.utf8)
        let frame = WebSocketUtils.createTextFrame(data: Data(data))
        
        let written = writeData(frame)
        if written < 0 {
            closeSocket()
            throw OBSWebSocketError.writeFailed
        }
    }
    
    func sendRecordingRequest() async throws -> Bool {
        // Request current recording status
        let request = """
        {"eventID":1,"data":{"requestType":"GetCurrentRecordingStatus"}}
        """
        let data = Array(request.utf8)
        let frame = WebSocketUtils.createTextFrame(data: Data(data))
        
        let written = writeData(frame)
        guard written > 0 else {
            throw OBSWebSocketError.writeFailed
        }
        
        // We'll receive the response via the event handler
        return currentRecordingState == .recording
    }
    
    // MARK: - Handshake
    
    private func performHandshake(host: String, port: Int) async throws {
        let socket = try createSocket(host: host, port: port)
        socketFD = socket
        
        // Generate WebSocket key
        var keyBytes = [UInt8](repeating: 0, count: 16)
        getrandom(&keyBytes, keyBytes.count)
        let key = Data(keyBytes).base64EncodedString()
        
        // Send HTTP upgrade request
        let request = """
        GET / HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r
        """
        
        let requestBytes = Array(request.utf8)
        let sent = writeData(requestBytes)
        
        guard sent > 0 else {
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Failed to send HTTP request")
        }
        
        // Read HTTP response
        var responseBuffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = readData(&responseBuffer, count: responseBuffer.count)
        
        guard bytesRead > 0 else {
            closeSocket()
            throw OBSWebSocketError.connectionFailed("No response from server")
        }
        
        responseBuffer[bytesRead] = 0
        let responseString = String(bytes: responseBuffer[0..<bytesRead], encoding: .utf8) ?? ""
        
        // Verify upgrade response
        guard responseString.contains("101") else {
            closeSocket()
            throw OBSWebSocketError.handshakeFailed("Server did not upgrade connection")
        }
        
        // Verify accept key
        let acceptHeader = extractHeader(responseString, name: "sec-websocket-accept")
        let expectedAccept = WebSocketUtils.computeAcceptKey(key: key)
        
        guard acceptHeader?.lowercased() == expectedAccept else {
            closeSocket()
            throw OBSWebSocketError.handshakeFailed("Invalid accept key")
        }
        
        // If token is provided, send authentication request
        if !token.isEmpty {
            try await sendAuthRequest()
        }
    }
    
    // MARK: - Event Handling
    
    private func startReceivingEvents() {
        Task { [weak self] in
            guard let self = self else { return }
            
            while self.isConnectedFlag {
                do {
                    try await self.receiveMessage()
                } catch {
                    if self.isConnectedFlag {
                        // Connection dropped
                        self.isConnectedFlag = false
                        await self.continuation?.yield(.unknown)
                        break
                    }
                }
            }
        }
    }
    
    private func receiveMessage() async throws {
        // Read WebSocket frame header
        var headerBuffer = [UInt8](repeating: 0, count: 14)
        let headerBytes = readData(&headerBuffer, count: 14)
        
        guard headerBytes >= 2 else {
            throw OBSWebSocketError.readFailed
        }
        
        let fin = headerBuffer[0] & 0x80
        let opcode = headerBuffer[0] & 0x0F
        let masked = headerBuffer[1] & 0x80
        var payloadLength = UInt64(headerBuffer[1] & 0x7F)
        
        let extraOffset: Int
        if payloadLength == 126 {
            guard headerBytes >= 4 else { throw OBSWebSocketError.readFailed }
            payloadLength = UInt64(headerBuffer[2]) << 8 | UInt64(headerBuffer[3])
            extraOffset = 4
        } else if payloadLength == 127 {
            guard headerBytes >= 10 else { throw OBSWebSocketError.readFailed }
            payloadLength = UInt64(headerBuffer[2...9]).bigEndian
            extraOffset = 10
        } else {
            extraOffset = 2
        }
        
        var dataOffset = extraOffset
        let maskingKey: [UInt8]
        
        if masked != 0 {
            maskingKey = headerBuffer[dataOffset..<dataOffset + 4]
            dataOffset += 4
        } else {
            maskingKey = [0, 0, 0, 0]
        }
        
        // Read payload
        let actualPayloadSize = min(Int(payloadLength), 10_000_000)
        var payloadBuffer = [UInt8](repeating: 0, count: actualPayloadSize)
        let payloadBytes = readData(&payloadBuffer, count: actualPayloadSize)
        
        // Unmask if server-masked
        if !maskingKey.isEmpty && payloadBytes > 0 {
            for i in 0..<payloadBytes {
                payloadBuffer[i] ^= maskingKey[i % 4]
            }
        }
        
        // Handle frames by opcode
        switch opcode {
        case 0x01:  // Text frame
            if let text = String(bytes: payloadBuffer[0..<payloadBytes], encoding: .utf8) {
                await handleMessage(text)
            }
            
        case 0x08:  // Close frame
            closeSocket()
            throw OBSWebSocketError.connectionLost
            
        case 0x09:  // Ping
            let pongFrame = WebSocketUtils.createBinaryFrame(data: Data())
            _ = writeData(pongFrame)
            
        default:
            break  // Ignore other frames
        }
    }
    
    private func handleMessage(_ message: String) async {
        do {
            guard let json = try JSONSerialization.jsonObject(with: message.data(using: .utf8)!) as? [String: Any] else {
                return
            }
            
            let opCode = json["op"] as? Int
            
            switch opCode {
            case 3:  // Heartbeat from OBS
                let heartbeat = """
                {"op":4,"data":{"interval":1000}}
                """
                let data = Array(heartbeat.utf8)
                let frame = WebSocketUtils.createTextFrame(data: Data(data))
                _ = writeData(frame)
                
            case 4:  // Ready event (OBS confirms connection)
                // Connection ready, can now send requests
                if !token.isEmpty {
                    // Authentication confirmed
                }
                
            case 5:  // Hello (initial message from OBS)
                // Extract heartbeat interval
                if let helloData = json["data"] as? [String: Any],
                   let heartbeatInterval = helloData["heartbeatInterval"] as? Int {
                    // Use heartbeat interval for connection monitoring
                }
                
            default:
                break
            }
        } catch {
            // Ignore parse errors
        }
    }
    
    // MARK: - Connection Management
    
    private func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }
    
    private func createSocket(host: String, port: Int) throws -> Int32 {
        let hostname = String(cString: host)
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        
        var result: UnsafeMutablePointer<addrinfo>?
        let addrResult = getaddrinfo(hostname, String(port), &hints, &result)
        
        guard addrResult == 0, let addr = result else {
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Could not resolve hostname \(host)")
        }
        defer { freeaddrinfo(result) }
        
        let socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else {
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Could not create socket")
        }
        
        // Set non-blocking
        let flags = fcntl(socket, F_GETFL)
        fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        
        // Set timeouts
        let timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        // Connect
        let sockaddr = UnsafeMutablePointer<sockaddr>(addr.ai_addr)
        let connectResult = connect(socket, sockaddr, socklen_t(addr.ai_addrlen))
        
        if connectResult < 0 && errno != EINPROGRESS {
            close(socket)
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Connection to \(host):\(port) failed: \(String(cString: strerror(errno)))")
        }
        
        // Wait for connection to complete
        var socketFdSet = fd_set()
        FD_ZERO(&socketFdSet)
        FD_SET(socket, &socketFdSet)
        
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        let selectResult = select(socket + 1, nil, &socketFdSet, nil, &tv)
        
        if selectResult <= 0 {
            close(socket)
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Connection timed out")
        }
        
        // Check for error
        var error: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &errorLen)
        
        if error != 0 {
            close(socket)
            closeSocket()
            throw OBSWebSocketError.connectionFailed("Connection error: \(String(cString: strerror(error)))")
        }
        
        // Restore blocking mode
        var flags2 = fcntl(socket, F_GETFL)
        fcntl(socket, F_SETFL, flags2 & ~O_NONBLOCK)
        
        return socket
    }
    
    private func readData(_ buffer: inout [UInt8], count: Int) -> Int {
        var readBytes = 0
        while readBytes < count {
            let n = read(socketFD, &buffer[readBytes], count - readBytes)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return readBytes > 0 ? readBytes : -1
            }
            if n == 0 {
                return readBytes > 0 ? readBytes : -1
            }
            readBytes += n
        }
        return readBytes
    }
    
    private func writeData(_ data: [UInt8]) -> Int {
        var written = 0
        while written < data.count {
            let n = write(socketFD, &data[written], data.count - written)
            if n <= 0 {
                return written > 0 ? written : -1
            }
            written += n
        }
        return written
    }
    
    private func extractHeader(_ response: String, name: String) -> String? {
        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = trimmed.lowercased().firstIndex(of: ":") {
                let headerName = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
                if headerName == name {
                    return String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}

// MARK: - WebSocket Utilities

private enum WebSocketUtils {
    static func computeAcceptKey(key: String) -> String {
        // SHA-1 hash of key + magic GUID, then base64 encode
        let combined = key + "258EAFA5-E914-47DA-95CA5CAB11496D43"
        let combinedData = combined.data(using: .utf8)!
        let hash = SHA1.hash(data: combinedData)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - SHA1 (using CryptoKit)

private extension SHA1 {
    static func hash(data: Data) -> [UInt8] {
        // CryptoKit returns UInt8 array via Digest
        let digest = Insecure.SHA1.hash(data: data)
        var result = [UInt8](repeating: 0, count: digest.count)
        result = digest.bytes
        return result
    }
}
