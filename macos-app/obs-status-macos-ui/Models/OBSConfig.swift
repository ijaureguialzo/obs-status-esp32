//
//  OBSConfig.swift
//  OBS connection configuration model and recording state.
//

import Foundation

struct OBSConfig: Codable {
    var host: String
    var port: Int
    var token: String
    /// Use `wss://` (TLS) instead of plain `ws://`.
    var secure: Bool

    init(host: String = "localhost", port: Int = 4455, token: String = "", secure: Bool = false) {
        self.host = host
        self.port = port
        self.token = token
        self.secure = secure
    }
}

enum RecordingState: Equatable, Sendable {
    case recording
    case notRecording
    case unknown
}