//
//  USBCDCService.swift
//  USB CDC (Virtual Serial Port) service for ESP32 communication
//  Uses IOKit to enumerate and communicate with USB serial devices.
//

import Foundation
#if canImport(Darwin)
import IOKit
import IOKit.usb
import IOKit.serial
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
    open var connectedDevice: USBDevice?
    private var isConnectedFlag: Bool = false
    
    var isConnected: Bool {
        isConnectedFlag
    }
    
    // MARK: - Public API
    
    func enumerateDevices() async -> [USBDevice] {
#if canImport(Darwin)
        await Task {
            var devices: [USBDevice] = []
            
            // Use IOKit to find all serial devices
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue as String) as CFMutableDictionary? else {
                return []
            }
            
            var matchingDict: io_object_t = 0
            let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &matchingDict)
            
            guard status == KERN_SUCCESS else {
                return []
            }
            
            guard matchingDict != 0 else {
                return []
            }
            
            let iterator = matchingDict
            
            var service = IOIteratorNext(iterator)
            
            while service != 0 {
                let name = getCFStringProperty(service, key: "name") ?? "Unknown Device"
                let callout = getCFStringProperty(service, key: "CalloutDevices")
                let serialPath = getCFStringProperty(service, key: "DialinDevices")
                
                let usbVendorID: UInt16? = getCFProperty(service, key: kUSBVendorID as CFString)
                let usbProductID: UInt16? = getCFProperty(service, key: kUSBProductID as CFString)
                let usbSerialNumber: String? = getCFStringProperty(service, key: "usbSerialNumber")
                
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
#else
        return []
#endif
    }
    
    func connect(_ device: USBDevice) async throws {
        guard fileDescriptor < 0 else {
            throw USBCDCError.alreadyConnected
        }
        
        fileDescriptor = open(device.path, O_RDWR | O_NOCTTY)
        if fileDescriptor < 0 {
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        var termios = termios()
        tcgetattr(fileDescriptor, &termios)
        
        cfsetispeed(&termios, speed_t(B115200))
        cfsetospeed(&termios, speed_t(B115200))
        
        termios.c_cflag |= UInt(CLOCAL | CREAD)
        termios.c_cflag &= ~UInt(PARENB)
        termios.c_cflag &= ~UInt(CSTOPB)
        termios.c_cflag &= ~UInt(CSIZE)
        termios.c_cflag |= UInt(CS8)
        
        termios.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ECHOK | ECHONL | ISIG | IEXTEN)
        termios.c_lflag &= ~UInt(ECHOK | ECHOCTL | ECHOKE)
        
        termios.c_oflag &= ~UInt(OPOST)
        
        termios.c_cflag &= ~UInt(CRTSCTS)
        termios.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        
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
        
        let data = command.data(using: .utf8)!
        let written = write(fileDescriptor, data.bytes, data.count)
        
        if written < 0 {
            let err = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw USBCDCError.writeFailed(error: err)
        }
        
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
    
    private func getCFStringProperty(_ service: io_object_t, key: String) -> String? {
        let result = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        defer { result?.release() }
        return result?.takeRetainedValue() as? String
    }
    
    private func getCFProperty<T>(_ service: io_object_t, key: CFString) -> T? {
        let result = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)
        defer { result?.release() }
        return result?.takeRetainedValue() as? T
    }
    
    private func isValidSerialPath(_ path: String) -> Bool {
        let validPrefixes = ["/dev/cu.", "/dev/cu.serial", "/dev/cu.usb"]
        return validPrefixes.contains { path.hasPrefix($0) }
    }
}

extension Data {
    var bytes: [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        copyBytes(to: &buffer, count: count * MemoryLayout<UInt8>.size)
        return buffer
    }
}