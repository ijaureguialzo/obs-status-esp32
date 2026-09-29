//
//  USBCDCService.swift
//  USB CDC (Virtual Serial Port) service for ESP32 communication
//

import Foundation
import IOKit
import IOKit.usb

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let kIOServiceInterestedNotification = kIOServiceMatch as CFString

protocol USBCDCServiceProtocol {
    var connectedDevice: USBDevice? { get }
    var isConnected: Bool { get }
    
    func enumerateDevices() async -> [USBDevice]
    func connect(_ device: USBDevice) async throws
    func disconnect()
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String
}

class USBCDCService: @unchecked Sendable, USBCDCServiceProtocol {
    private var fileDescriptor: Int32 = -1
    private var connectedDevice: USBDevice?
    private var isConnectedFlag: Bool = false
    private var readTask: Task<Void, Error>?
    
    var isConnected: Bool {
        isConnectedFlag
    }
    
    func enumerateDevices() async -> [USBDevice] {
        await Task {
            var serviceIterator: io_iterator_t?
            var matchingDict: io_object_t = 0
            
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary else {
                return []
            }
            
            // Match all serial devices
            matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
            
            guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &serviceIterator) == KERN_SUCCESS,
                  let iterator = serviceIterator else {
                return []
            }
            
            var devices: [USBDevice] = []
            var service = IOIteratorNext(iterator)
            
            while service != 0 {
                if let name = IORegistryEntryCreateCFProperty(service, kIONameKey as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String,
                   let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String,
                   let vendorID = IORegistryEntryCreateCFProperty(service, kUSBVendorID as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as UInt16?,
                   let productID = IORegistryEntryCreateCFProperty(service, kUSBProductID as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as UInt16? {
                    
                    let serialNumber = IORegistryEntryCreateCFProperty(service, kUSBSerialNumber as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String
                    
                    if USBCDFilter.isValidSerialPath(path) {
                        devices.append(USBDevice(
                            vendorID: vendorID,
                            productID: productID,
                            serialNumber: serialNumber,
                            name: name,
                            path: path
                        ))
                    }
                }
                
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            
            IOObjectRelease(iterator)
            return devices
        }.value
    }
    
    func connect(_ device: USBDevice) async throws {
        guard fileDescriptor < 0 else {
            throw USBCDCError.alreadyConnected
        }
        
        // Open the serial port
        fileDescriptor = open(device.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fileDescriptor < 0 {
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        // Configure baud rate (115200)
        var termios = termios()
        tcgetattr(fileDescriptor, &termios)
        
        cfsetispeed(&termios, speed_t(BAUD_115200))
        cfsetospeed(&termios, speed_t(BAUD_115200))
        
        termios.c_cflag |= (CLOCAL | CREAD)
        termios.c_cflag &= ~PARENB
        termios.c_cflag &= ~CSTOPB
        termios.c_cflag &= ~CSIZE
        termios.c_cflag |= CS8
        termios.c_lflag &= ~(ICANON | ECHO | ISIG)
        termios.c_oflag &= ~OPOST
        
        tcsetattr(fileDescriptor, TCSANOW, &termios)
        
        // Restore blocking mode for reads
        var flags = fcntl(fileDescriptor, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fileDevice, F_SETFL, flags)
        
        connectedDevice = device
        isConnectedFlag = true
    }
    
    func disconnect() {
        close(fileDescriptor)
        fileDescriptor = -1
        connectedDevice = nil
        isConnectedFlag = false
        readTask?.cancel()
        readTask = nil
    }
    
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String {
        guard fileDescriptor >= 0 else {
            throw USBCDCError.notConnected
        }
        
        let data = command.data(using: .utf8)!
        let written = write(fileDescriptor, data.bytes, data.count)
        
        if written < 0 {
            throw USBCDCError.writeFailed(error: errno)
        }
        
        // Read response (timeout: 2 seconds)
        var responseBuffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(fileDescriptor, &responseBuffer, responseBuffer.count)
        
        if bytesRead > 0 {
            if let response = String(bytes: responseBuffer[0..<bytesRead], encoding: .utf8) {
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return ""
    }
    
    deinit {
        disconnect()
    }
}

// MARK: - Filter Helpers

private enum USBCDFilter {
    static func isValidSerialPath(_ path: String) -> Bool {
        let validPrefixes = ["/dev/cu.", "/dev/cu.serial"]
        return validPrefixes.contains { path.hasPrefix($0) }
    }
}

// MARK: - Error Types

enum USBCDCError: LocalizedError {
    case alreadyConnected
    case notConnected
    case cannotOpen(path: String)
    case writeFailed(error: Int32)
    
    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "Already connected to an ESP32 device"
        case .notConnected:
            return "Not connected to any ESP32 device"
        case .cannotOpen(let path):
            return "Cannot open serial port: \(path)"
        case .writeFailed(let err):
            return "Write failed with error code: \(err)"
        }
    }
}
