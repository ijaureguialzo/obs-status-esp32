//
//  USBDevice.swift
//  USB device model for ESP32 identification.
//  Used to enumerate and filter serial devices.
//

import Foundation

struct USBDevice: Identifiable, Codable, Hashable {
    let id: String
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let deviceDescription: String?
    let name: String
    let path: String
    
    nonisolated init(
        vendorID: UInt16,
        productID: UInt16,
        serialNumber: String?,
        deviceDescription: String? = nil,
        name: String,
        path: String
    ) {
        self.id = path
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.deviceDescription = deviceDescription
        self.name = name
        self.path = path
    }

    var pickerTitle: String {
        let label = deviceDescription ?? (name == "Unknown Device" ? String(localized: "Serial device") : name)
        return "\(label) — \(path)"
    }
}

extension USBDevice {
    /// Known ESP32 USB vendor IDs for filtering devices
    static let esp32VendorIDs: [UInt16] = [
        0x303A, // Espressif
        0x10C4, // Silicon Labs CP210x
        0x1A86, // CH340/CH9102
        0x28E9, // STMicroelectronics
        0x1209, // Freenove
    ]
    
    static func isESP32Device(_ vendorID: UInt16) -> Bool {
        esp32VendorIDs.contains(vendorID)
    }
}