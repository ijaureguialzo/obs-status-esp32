//
//  AppSettings.swift
//  Persistent application settings storage.
//  Saves OBS configuration and connection preferences.
//

import Foundation
import os
import Security

private enum Key {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.unknown.obs-status"
    static var settingsFile: String { "Preferences/\(bundleID).json" }
    static let obsConfigKey = "obsConfig"
    static let espDevicePathKey = "lastESPDevicePath"
    static let autoConnectKey = "autoConnect"
    static let tokenAccount = "obs-websocket-token"
}

class AppSettings {
    static let shared = AppSettings()
    
    private let fileURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ObsStatus", category: "Settings")
    
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
                    let savedToken: String
                    do {
                        savedToken = try loadToken() ?? (configDict["token"] as? String ?? "")
                    } catch {
                        logger.error("Unable to load OBS token from Keychain: \(error.localizedDescription, privacy: .public)")
                        savedToken = configDict["token"] as? String ?? ""
                    }
                    _obsConfig = OBSConfig(
                        host: configDict["host"] as? String ?? "localhost",
                        port: configDict["port"] as? Int ?? 4455,
                        token: savedToken
                    )
                }
                _lastESPDevicePath = json[Key.espDevicePathKey] as? String
                _autoConnect = (json[Key.autoConnectKey] as? Bool) ?? false
                if json[Key.obsConfigKey] is [String: Any],
                   (json[Key.obsConfigKey] as? [String: Any])?["token"] is String {
                    save()
                }
            }
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            logger.error("Unable to load settings: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func save() {
        do {
            var dict: [String: Any] = [
                Key.obsConfigKey: [
                    "host": _obsConfig.host,
                    "port": _obsConfig.port,
                ],
                Key.autoConnectKey: _autoConnect,
            ]
            if let lastESPDevicePath = _lastESPDevicePath {
                dict[Key.espDevicePathKey] = lastESPDevicePath
            }
            
            do {
                try saveToken(_obsConfig.token)
            } catch {
                logger.error("Unable to save OBS token to Keychain: \(error.localizedDescription, privacy: .public)")
            }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Unable to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.bundleID,
            kSecAttrAccount as String: Key.tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return token
    }

    private func saveToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.bundleID,
            kSecAttrAccount as String: Key.tokenAccount,
        ]
        guard !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery.merge(attributes) { _, new in new }
            let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(insertStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}