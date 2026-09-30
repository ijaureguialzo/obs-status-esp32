//
//  AppSettings.swift
//  Persistent application settings storage.
//  Saves OBS configuration and connection preferences.
//

import Foundation

private enum Key {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.unknown.obs-status"
    static let settingsFile = "obs-status-config.json"
    static let obsConfigKey = "obsConfig"
    static let espDevicePathKey = "lastESPDevicePath"
    static let autoConnectKey = "autoConnect"
}

class AppSettings {
    static let shared = AppSettings()
    
    private let fileURL: URL
    
    private var _obsConfig: OBSConfig
    private var _lastESPDevicePath: String?
    private var _autoConnect: Bool
    
    var obsConfig: OBSConfig {
        get { _obsConfig }
        set { _obsConfig = newValue; save() }
    }
    
    var lastESPDevicePath: String? {
        get { _lastESPDevicePath }
        set { _lastESPDevicePath = newValue; save() }
    }
    
    var autoConnect: Bool {
        get { _autoConnect }
        set { _autoConnect = newValue; save() }
    }
    
    private init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        fileURL = directory.appendingPathComponent(Key.settingsFile)
        
        _obsConfig = OBSConfig()
        _lastESPDevicePath = nil
        _autoConnect = false
        
        load()
    }
    
    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let configDict = json[Key.obsConfigKey] as? [String: Any] {
                    _obsConfig = OBSConfig(
                        host: configDict["host"] as? String ?? "localhost",
                        port: configDict["port"] as? Int ?? 4444,
                        token: configDict["token"] as? String ?? ""
                    )
                }
                _lastESPDevicePath = json[Key.espDevicePathKey] as? String
                _autoConnect = (json[Key.autoConnectKey] as? Bool) ?? false
            }
        } catch {
            // Use defaults
        }
    }
    
    private func save() {
        do {
            let dict: [String: Any] = [
                Key.obsConfigKey: [
                    "host": _obsConfig.host,
                    "port": _obsConfig.port,
                    "token": _obsConfig.token,
                ],
                Key.espDevicePathKey: _lastESPDevicePath as Any,
                Key.autoConnectKey: _autoConnect,
            ]
            
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Silently fail
        }
    }
}
