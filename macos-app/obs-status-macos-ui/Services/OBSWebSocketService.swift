//
//  OBSWebSocketService.swift
//  WebSocket client for OBS Studio obs-websocket API
//

import Foundation
import CryptoKit

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
    private var socketFD: Int32 = -1
    private var isConnectedFlag: Bool = false
    private var currentRecordingState: RecordingState = .unknown
    private var continuation: AsyncStream<RecordingState>.Continuation?
    private var host: String?
    private var port: Int?
    private var token: String?
    
    var isConnected: Bool { isConnectedFlag }
    var recordingState: RecordingState { currentRecordingState }
    
    var recordingStateStream: AsyncStream<RecordingState> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    func connect(host: String, port: Int, token: String) async throws {
        guard !isConnected else { return }
        self.host = host
        self.port = port
        self.token = token
        do {
            try await performHandshake(host: host, port: port)
            isConnectedFlag = true
            startReceivingEvents()
        } catch {
            closeSocket()
            throw error
        }
    }
    
    func disconnect() {
        host = nil; port = nil; token = nil
        isConnectedFlag = false
        closeSocket()
        currentRecordingState = .unknown
        continuation?.finish()
        continuation = nil
    }
    
    func sendAuthRequest() async throws {
        guard let token = token, !token.isEmpty else { return }
        let authMessage = "{\"eventID\":1,\"data\":{\"requestType\":\"Authenticate\",\"requestData\":{\"auth\":\"\(token)\"}}}"
        let frame = WebSocketUtils.createTextFrame(data: Data(authMessage.utf8))
        let written = writeData(frame)
        if written < 0 { closeSocket(); throw OBSWebSocketError.writeFailed }
    }
    
    func sendRecordingRequest() async throws -> Bool {
        let request = "{\"eventID\":1,\"data\":{\"requestType\":\"GetCurrentRecordingStatus\"}}"
        let frame = WebSocketUtils.createTextFrame(data: Data(request.utf8))
        guard writeData(frame) > 0 else { throw OBSWebSocketError.writeFailed }
        return currentRecordingState == .recording
    }
    
    private func performHandshake(host: String, port: Int) async throws {
        let socket = try createSocket(host: host, port: port)
        socketFD = socket
        var keyBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            closeSocket(); throw OBSWebSocketError.connectionFailed("Failed to generate random key")
        }
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard writeData(Array(request.utf8)) > 0 else { closeSocket(); throw OBSWebSocketError.connectionFailed("Failed to send HTTP request") }
        var responseBuffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = readData(&responseBuffer, count: responseBuffer.count)
        guard bytesRead > 0 else { closeSocket(); throw OBSWebSocketError.connectionFailed("No response from server") }
        responseBuffer[bytesRead] = 0
        let responseString = String(bytes: responseBuffer[0..<bytesRead], encoding: .utf8) ?? ""
        guard responseString.contains("101") else { closeSocket(); throw OBSWebSocketError.handshakeFailed("Server did not upgrade connection") }
        let acceptHeader = extractHeader(responseString, name: "sec-websocket-accept")
        let expectedAccept = WebSocketUtils.computeAcceptKey(key: key)
        guard acceptHeader?.lowercased() == expectedAccept else { closeSocket(); throw OBSWebSocketError.handshakeFailed("Invalid accept key") }
        if let token = token, !token.isEmpty { try await sendAuthRequest() }
    }
    
    private func startReceivingEvents() {
        _ = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            while self.isConnectedFlag {
                do { try await self.receiveMessage() }
                catch {
                    if self.isConnectedFlag {
                        self.isConnectedFlag = false
                        await self.continuation?.yield(.unknown)
                        break
                    }
                }
            }
        }
    }
    
    private func receiveMessage() async throws {
        var headerBuffer = [UInt8](repeating: 0, count: 14)
        let headerBytes = readData(&headerBuffer, count: 14)
        guard headerBytes >= 2 else { throw OBSWebSocketError.readFailed }
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
            payloadLength = headerBuffer[2...9].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            extraOffset = 10
        } else {
            extraOffset = 2
        }
        var dataOffset = extraOffset
        var maskingKey: [UInt8] = [0, 0, 0, 0]
        if masked != 0 {
            maskingKey = Array(headerBuffer[dataOffset..<dataOffset + 4])
            dataOffset += 4
        }
        let actualPayloadSize = min(Int(payloadLength), 10_000_000)
        var payloadBuffer = [UInt8](repeating: 0, count: actualPayloadSize)
        let payloadBytes = readData(&payloadBuffer, count: actualPayloadSize)
        if !maskingKey.isEmpty && payloadBytes > 0 {
            for i in 0..<payloadBytes { payloadBuffer[i] ^= maskingKey[i % 4] }
        }
        switch opcode {
        case 0x01: if let text = String(bytes: payloadBuffer[0..<payloadBytes], encoding: .utf8) { await handleMessage(text) }
        case 0x08: closeSocket(); throw OBSWebSocketError.connectionLost
        case 0x09: _ = writeData(WebSocketUtils.createBinaryFrame(data: Data()))
        default: break
        }
    }
    
    private func handleMessage(_ message: String) async {
        do {
            guard let json = try JSONSerialization.jsonObject(with: message.data(using: .utf8)!) as? [String: Any] else { return }
            switch json["op"] as? Int {
            case 3: let hb = "{\"op\":4,\"data\":{\"interval\":1000}}"; _ = writeData(WebSocketUtils.createTextFrame(data: Data(hb.utf8)))
            case 4: break
            case 5: break
            default: break
            }
        } catch {}
    }
    
    private func closeSocket() { if socketFD >= 0 { close(socketFD); socketFD = -1 } }
    
    private func createSocket(host: String, port: Int) throws -> Int32 {
        // Stub: low-level socket creation not yet implemented for Swift 6
        // TODO: Implement socket creation when Swift 6 Darwin bindings are stable
        throw OBSWebSocketError.connectionFailed("Socket creation not yet implemented for Swift 6")
    }
    
    private func readData(_ buffer: inout [UInt8], count: Int) -> Int {
        var readBytes = 0
        while readBytes < count {
            let n = read(socketFD, &buffer[readBytes], count - readBytes)
            if n < 0 { if errno == EAGAIN || errno == EWOULDBLOCK { continue }; return readBytes > 0 ? readBytes : -1 }
            if n == 0 { return readBytes > 0 ? readBytes : -1 }
            readBytes += n
        }
        return readBytes
    }
    
    private func writeData(_ data: [UInt8]) -> Int {
        var written = 0
        while written < data.count {
            var mutableData = data
            let n = write(socketFD, &mutableData[written], data.count - written)
            if n <= 0 { return written > 0 ? written : -1 }
            written += n
        }
        return written
    }
    
    private func extractHeader(_ response: String, name: String) -> String? {
        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = trimmed.lowercased().firstIndex(of: ":") {
                let headerName = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
                if headerName == name { return String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

private enum WebSocketUtils {
    static func computeAcceptKey(key: String) -> String {
        let combined = key + "258EAFA5-E914-47DA-95CA5CAB11496D43"
        let digest = Insecure.SHA1.hash(data: combined.data(using: .utf8)!)
        return Data(Array(digest)).base64EncodedString()
    }
    static func createTextFrame(data: Data) -> [UInt8] {
        var frame = [UInt8](); frame.append(0x81)
        if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
        else if data.count < 65536 { frame.append(0x80 | 126); let len = UInt16(data.count).bigEndian; frame.append(UInt8(len >> 8)); frame.append(UInt8(len & 0xFF)) }
        else { frame.append(0x80 | 127); let len = UInt64(data.count).bigEndian; for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) } }
        frame.append(contentsOf: data); return frame
    }
    static func createBinaryFrame(data: Data) -> [UInt8] {
        var frame = [UInt8](); frame.append(0x82)
        if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
        else if data.count < 65536 { frame.append(0x80 | 126); let len = UInt16(data.count).bigEndian; frame.append(UInt8(len >> 8)); frame.append(UInt8(len & 0xFF)) }
        else { frame.append(0x80 | 127); let len = UInt64(data.count).bigEndian; for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) } }
        frame.append(contentsOf: data); return frame
    }
}
