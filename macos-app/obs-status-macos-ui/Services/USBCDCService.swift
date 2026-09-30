//
//  USBCDCService.swift
//  USB serial service for ESP32 communication
//  Handles both CDC-ACM devices (standard USB serial) and
//  USB Serial JTAG devices (ESP32-S3 native USB).
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
            return err == 0 ? "Timed out waiting for ESP32 response" : "Read failed with error code: \(err)"
        case .invalidBaudRate:
            return "Invalid baud rate configured"
        }
    }
}

protocol USBCDCServiceProtocol: Sendable {
    /// Yields whenever a serial device is plugged in or removed.
    nonisolated var deviceEvents: AsyncStream<Void> { get }
    func enumerateDevices() async -> [USBDevice]
    func connect(_ device: USBDevice) async throws
    func disconnect() async
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String
}

/// Broadcasts device change events to any number of stream subscribers.
/// IOKit callbacks arrive on a dispatch queue, so access is lock-based
/// and the type is usable from outside the actor.
private final class DeviceEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.continuations[id] = nil }
            }
        }
    }

    func broadcast() {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current {
            continuation.yield()
        }
    }
}

actor USBCDCService: USBCDCServiceProtocol {
    // MARK: - Properties
    
    private var fileDescriptor: Int32 = -1
    private var connectedDevice: USBDevice?
    private var isConnectedFlag: Bool = false
    private let broadcaster = DeviceEventBroadcaster()
    private var notificationsStarted = false
#if canImport(Darwin)
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
#endif

    nonisolated var deviceEvents: AsyncStream<Void> {
        broadcaster.stream()
    }
    
    // MARK: - Public API
    
    func enumerateDevices() async -> [USBDevice] {
        startMonitoring()
#if canImport(Darwin)
        return await Task {
            var devices: [USBDevice] = []
            
            // Check for USB Serial JTAG (ESP32-S3 native)
            // Appears as /dev/cu.debug-console
            let jtagPath = "/dev/cu.debug-console"
            if FileManager.default.fileExists(atPath: jtagPath) {
                // Avoid adding if already found via IOKit enumeration
                let alreadyExists = devices.contains { $0.path == jtagPath }
                if !alreadyExists {
                    devices.append(USBDevice(
                        vendorID: 0x303A, // Espressif
                        productID: 0x0001,
                        serialNumber: nil,
                        deviceDescription: "USB JTAG/serial debug unit",
                        name: "ESP32-S3 USB Serial JTAG",
                        path: jtagPath
                    ))
                }
            }
            
            // Also enumerate CDC-ACM devices (CP210x, CH340, FTDI, etc.)
            // This handles other boards that enumerate as standard USB serial
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue as String) as CFMutableDictionary? else {
                return devices
            }
            
            var matchingDict: io_object_t = 0
            let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &matchingDict)
            
            guard status == KERN_SUCCESS else {
                return devices
            }
            
            guard matchingDict != 0 else {
                return devices
            }
            
            let iterator = matchingDict
            
            var service = IOIteratorNext(iterator)
            
            while service != 0 {
                let name = getCFStringProperty(service, key: "name") ?? "Serial device"
                let callout = getCFStringProperty(service, key: "IOCalloutDevice")
                let serialPath = getCFStringProperty(service, key: "IODialinDevice")
                
                let usbVendorID: UInt16? = getCFProperty(service, key: kUSBVendorID as CFString)
                let usbProductID: UInt16? = getCFProperty(service, key: kUSBProductID as CFString)
                let usbDescription: String? = getCFProperty(service, key: kUSBProductString as CFString)
                let usbSerialNumber: String? = getCFProperty(service, key: kUSBSerialNumberString as CFString)
                
                let devicePath = callout ?? serialPath
                if let path = devicePath, isValidSerialPath(path) {
                    // Avoid duplicates
                    let exists = devices.contains { $0.path == path }
                    if !exists {
                        devices.append(USBDevice(
                            vendorID: usbVendorID ?? 0,
                            productID: usbProductID ?? 0,
                            serialNumber: usbSerialNumber,
                            deviceDescription: usbDescription,
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
        
        var settings = termios()
        guard tcgetattr(fileDescriptor, &settings) == 0 else {
            close(fileDescriptor)
            fileDescriptor = -1
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        cfsetispeed(&settings, speed_t(B115200))
        cfsetospeed(&settings, speed_t(B115200))
        
        settings.c_cflag |= UInt(CLOCAL | CREAD)
        settings.c_cflag &= ~UInt(PARENB)
        settings.c_cflag &= ~UInt(CSTOPB)
        settings.c_cflag &= ~UInt(CSIZE)
        settings.c_cflag |= UInt(CS8)
        
        settings.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ECHOK | ECHONL | ISIG | IEXTEN)
        settings.c_lflag &= ~UInt(ECHOK | ECHOCTL | ECHOKE)
        
        settings.c_oflag &= ~UInt(OPOST)
        
        settings.c_cflag &= ~UInt(CRTSCTS)
        settings.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        settings.c_cc.16 = 0
        settings.c_cc.17 = 1
        
        if tcsetattr(fileDescriptor, TCSANOW, &settings) < 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            throw USBCDCError.cannotOpen(path: device.path)
        }
        
        connectedDevice = device
        isConnectedFlag = true
    }
    
    func disconnect() async {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        connectedDevice = nil
        isConnectedFlag = false
    }
    
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String {
        guard fileDescriptor >= 0, connectedDevice?.path == device.path else {
            throw USBCDCError.notConnected
        }
        
        let data = Data(command.utf8)
        let writeResult = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                guard let baseAddress = buffer.baseAddress else { return false }
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard writeResult else { throw USBCDCError.writeFailed(error: errno) }
        
        var response: [UInt8] = []
        response.reserveCapacity(128)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while response.count < 256 {
            var byte: UInt8 = 0
            let bytesRead = read(fileDescriptor, &byte, 1)
            if bytesRead < 0, errno == EINTR {
                continue
            }
            if bytesRead == 0, DispatchTime.now().uptimeNanoseconds < deadline {
                continue
            }
            guard bytesRead > 0 else { throw USBCDCError.readFailed(error: errno) }
            if byte == 0x0A {
                return String(decoding: response, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            response.append(byte)
        }
        throw USBCDCError.readFailed(error: EMSGSIZE)
    }
    
    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
#if canImport(Darwin)
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
#endif
    }
    
    // MARK: - Device monitoring
    
    private func startMonitoring() {
#if canImport(Darwin)
        guard !notificationsStarted else { return }
        notificationsStarted = true
        
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .global(qos: .utility))
        
        let refcon = Unmanaged.passUnretained(broadcaster).toOpaque()
        for notification in [kIOFirstPublishNotification, kIOTerminatedNotification] {
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue as String) else { continue }
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port, notification, matching,
                Self.deviceChangeCallback, refcon, &iterator
            )
            guard status == KERN_SUCCESS else { continue }
            // Drain the initial batch; the iterator stays armed for future changes.
            Self.drain(iterator)
            if notification == kIOFirstPublishNotification {
                addedIterator = iterator
            } else {
                removedIterator = iterator
            }
        }
#endif
    }
    
#if canImport(Darwin)
    private nonisolated static let deviceChangeCallback: IOServiceMatchingCallback = { refcon, iterator in
        USBCDCService.drain(iterator)
        guard let refcon else { return }
        Unmanaged<DeviceEventBroadcaster>.fromOpaque(refcon)
            .takeUnretainedValue()
            .broadcast()
    }
    
    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
#endif
    
    // MARK: - Helpers
    
    private func getCFStringProperty(_ service: io_object_t, key: String) -> String? {
        let result = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return result?.takeRetainedValue() as? String
    }
    
    private func getCFProperty<T>(_ service: io_object_t, key: CFString) -> T? {
        let result = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        )
        return result as? T
    }
    
    private func isValidSerialPath(_ path: String) -> Bool {
        let validPrefixes = ["/dev/cu.", "/dev/cu.serial", "/dev/cu.usb"]
        return validPrefixes.contains { path.hasPrefix($0) }
    }
}
