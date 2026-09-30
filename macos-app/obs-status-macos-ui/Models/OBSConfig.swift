//
//  OBSConfig.swift
//  OBS connection configuration model and recording state.
//

import Foundation

struct OBSConfig: Codable {
    var host: String
    var port: Int
    var token: String
    
    init(host: String = "localhost", port: Int = 4455, token: String = "") {
        self.host = host
        self.port = port
        self.token = token
    }
}

enum RecordingState: Equatable, Sendable {
    case recording
    case notRecording
    case unknown
}