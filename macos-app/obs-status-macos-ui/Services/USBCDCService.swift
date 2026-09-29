//
//  USBCDCService.swift
//  USB CDC (Virtual Serial Port) service for ESP32 communication
//  Uses IOKit to enumerate and communicate with USB serial devices.
//

import Foundation
import IOKit
import IOKit.usb

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum USBCDCError: LocalizedError {
    case alreadyConnected
    case notConnected
    case cannotOpen(path: String)
    case writeFailed(error: Int32)
    case readFailed(error: Int32)
    case invalidBaudRate
    
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
        case .readFailed(let err):
            return "Read failed with error code: \(err)"
        case .invalidBaudRate:
            return "Invalid baud rate configured"
        }
    }
}

protocol USBCDCServiceProtocol: Sendable {
    var connectedDevice: USBDevice? { get }
    var isConnected: Bool { get }
    
    func enumerateDevices() async -> [USBDevice]
    func connect(_ device: USBDevice) async throws
    func disconnect()
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String
}

class USBCDCService: @unchecked Sendable, USBCDCServiceProtocol {
    // MARK: - Properties
    
    private var fileDescriptor: Int32 = -1
    private var connectedDevice: USBDevice?
    private var isConnectedFlag: Bool = false
    
    var isConnected: Bool {
        isConnectedFlag
    }
    
    // MARK: - Public API
    
    func enumerateDevices() async -> [USBDevice] {
        await Task {
            var devices: [USBDevice] = []
            
            // Use IOKit to find all serial devices
            var matchingDict: io_iterator_t?
            let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
            matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
            
            let status = IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &matchingDict)
            
            guard status == KERN_SUCCESS, let iterator = matchingDict else {
                return []
            }
            
            var service = IOIteratorNext(iterator)
            
            while service != 0 {
                // Get device info from registry
                let name = IORegistryEntryCreateCFProperty(service, kIONameKey as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? String ?? "Unknown Device"
                
                let callout = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? String
                
                let serialPath = IORegistryEntryCreateCFProperty(service, kIODialinDeviceKey as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? String
                
                // Get USB properties
                var usbVendorID: UInt16?
                var usbProductID: UInt16?
                var usbSerialNumber: String?
                
                // Navigate to USB interface
                var parent = IORegistryEntryCreateCFProperty(service, kIOProviderClassKey as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? String
                
                // Try to get USB properties directly
                if let vendorIDData = IORegistryEntryCreateCFProperty(service, kUSBVendorID as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? UInt16 {
                    usbVendorID = vendorIDData
                }
                
                if let productIDData = IORegistryEntryCreateCFProperty(service, kUSBProductID as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? UInt16 {
                    usbProductID = productIDData
                }
                
                if let serialNumberData = IORegistryEntryCreateCFProperty(service, kUSBSerialNumber as CFString, kCFAllocatorDefault, 0)
                    .takeRetainedValue() as? String {
                    usbSerialNumber = serialNumberData
                }
                
                // Use callout path or dialin path
                let devicePath = callout ?? serialPath
                if let path = devicePath, isValidSerialPath(path) {
                    devices.append(USBDevice(
                        vendorID: usbVendorID ?? 0,
                        productID: usbProductID ?? 0,
                        serialNumber: usbSerialNumber,
                        name: name,
                        path: path
                    ))
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
        fileDescriptor = open(device.path, O_RDWR | O_NOCTTY)
        if fileDescriptor < 0 {
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        // Configure serial port settings
        var termios = termios()
        tcgetattr(fileDescriptor, &termios)
        
        // Set baud rate to 115200
        cfsetispeed(&termios, speed_t(B115200))
        cfsetospeed(&termios, speed_t(B115200))
        
        // 8N1: 8 data bits, no parity, 1 stop bit
        termios.c_cflag |= (CLOCAL | CREAD)
        termios.c_cflag &= ~PARENB
        termios.c_cflag &= ~CSTOPB
        termios.c_cflag &= ~CSIZE
        termios.c_cflag |= CS8
        
        // Raw mode: no canonical processing, no echo, no signal processing
        termios.c_lflag &= ~(ICANON | ECHO | ECHOE | ECHOK | ECHONL | ISIG | IEXTEN)
        termios.c_lflag &= ~(ECHOK | ECHOCTL | ECHOKE)
        
        // Raw output: no post-processing
        termios.c_oflag &= ~OPOST
        
        // No flow control
        termios.c_cflag &= ~CRTSCTS
        termios.c_iflag &= ~(IXON | IXOFF | IXANY)
        
        // Set control character limits
        termios.c_cc[VMIN] = 1
        termios.c_cc[VTIME] = 20  // 2 second timeout
        
        // Apply settings
        if tcsetattr(fileDescriptor, TCSANOW, &termios) < 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        connectedDevice = device
        isConnectedFlag = true
    }
    
    func disconnect() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        connectedDevice = nil
        isConnectedFlag = false
    }
    
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String {
        guard fileDescriptor >= 0 else {
            throw USBCDCError.notConnected
        }
        
        // Send command
        let data = command.data(using: .utf8)!
        let written = write(fileDescriptor, data.bytes, data.count)
        
        if written < 0 {
            let err = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw USBCDCError.writeFailed(error: err)
        }
        
        // Read response with timeout
        var responseBuffer = [UInt8](repeating: 0, count: 256)
        var totalRead = 0
        var bytesRead: Int
        
        repeat {
            bytesRead = read(fileDescriptor, &responseBuffer[totalRead], responseBuffer.count - totalRead)
            if bytesRead > 0 {
                totalRead += bytesRead
            }
        } while bytesRead > 0 && totalRead < responseBuffer.count
        
        if totalRead > 0 {
            let response = String(bytes: responseBuffer[0..<totalRead], encoding: .utf8)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            
            if !response.isEmpty {
                return response
            }
        }
        
        return ""
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Helpers
    
    private func isValidSerialPath(_ path: String) -> Bool {
        let validPrefixes = ["/dev/cu.", "/dev/cu.serial", "/dev/cu.usb"]
        return validPrefixes.contains { path.hasPrefix($0) }
    }
}

// MARK: - Extensions for UnsafeRawPointer

extension Data {
    var bytes: [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        copyBytes(to: &buffer, count: count * MemoryLayout<UInt8>.size)
        return buffer
    }
}
