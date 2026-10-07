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
            return String(localized: "Already connected to an ESP32 device")
        case .notConnected:
            return String(localized: "Not connected to any ESP32 device")
        case .cannotOpen(let path):
            return String(localized: "Cannot open serial port: \(path)")
        case .writeFailed(let err):
            return String(localized: "Write failed with error code: \(String(err))")
        case .readFailed(let err):
            return err == 0
                ? String(localized: "Timed out waiting for ESP32 response")
                : String(localized: "Read failed with error code: \(String(err))")
        case .invalidBaudRate:
            return String(localized: "Invalid baud rate configured")
        }
    }
}

protocol USBCDCServiceProtocol: Sendable {
    /// Yields whenever a serial device is plugged in or removed.
    nonisolated var deviceEvents: AsyncStream<Void> { get }
    /// Unsolicited lines sent by the ESP32 (lines starting with `EVENT:`),
    /// e.g. a tap on the touch screen asking to toggle the recording pause.
    nonisolated var events: AsyncStream<String> { get }
    func enumerateDevices() async -> [USBDevice]
    func connect(_ device: USBDevice) async throws
    func disconnect() async
    func sendCommand(_ command: String, to device: USBDevice) async throws -> String
}

/// Broadcasts device change events to any number of stream subscribers.
/// IOKit callbacks arrive on a dispatch queue, so access is lock-based
/// and the type is usable from outside the actor.
private final class DeviceEventBroadcaster: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    nonisolated init() {}

    nonisolated func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.continuations[id] = nil }
            }
        }
    }

    nonisolated func broadcast() {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current {
            continuation.yield()
        }
    }
}

/// Routes lines read from the serial port by the detached reader loop:
/// lines starting with the event prefix are broadcast to event subscribers,
/// any other line completes the pending command response. Lock-based so the
/// reader thread and the actor can both use it safely.
private final class LineRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingID: UUID?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    /// Last well-formed response that arrived while no command was pending.
    /// Kept so a response that beats `registerPending` can still be matched;
    /// dropped before each write (see discardStaleResponse) so a late
    /// response from a previously timed-out command is never misattributed.
    private var stashedResponse: String?
    private var eventContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var stopped = true

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    var hasPending: Bool {
        lock.withLock { pendingContinuation != nil }
    }

    func eventStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { eventContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.eventContinuations[id] = nil }
            }
        }
    }

    func handleLine(_ line: String) {
        if line.hasPrefix(ObsEvent.linePrefix) {
            let subscribers = lock.withLock { Array(eventContinuations.values) }
            for continuation in subscribers {
                continuation.yield(line)
            }
            return
        }
        // Only well-formed responses complete a command. The firmware's log
        // output shares the USB Serial JTAG link, so stray lines (boot logs,
        // "Tap detected", ...) are dropped instead of being misdelivered.
        guard ObsResponse.isResponse(line) else {
            return
        }
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            if let continuation = pendingContinuation {
                pendingContinuation = nil
                pendingID = nil
                return continuation
            }
            // No command in flight: keep the response in case a command is
            // armed right after this line is read (see registerPending).
            stashedResponse = line
            return nil
        }
        pending?.resume(returning: line)
    }

    private enum Registration {
        /// A stashed response was consumed immediately.
        case immediate(String)
        case armed
        case rejected(USBCDCError)
    }

    func registerPending(id: UUID, continuation: CheckedContinuation<String, Error>) {
        let registration = lock.withLock { () -> Registration in
            if let stashed = stashedResponse {
                stashedResponse = nil
                return .immediate(stashed)
            }
            guard !stopped, pendingContinuation == nil else {
                return .rejected(USBCDCError.notConnected)
            }
            pendingID = id
            pendingContinuation = continuation
            return .armed
        }
        switch registration {
        case .immediate(let line):
            continuation.resume(returning: line)
        case .armed:
            return
        case .rejected(let error):
            continuation.resume(throwing: error)
        }
    }

    /// Drops any stashed response before a new command is written, so a
    /// late response from a previously timed-out command cannot be mistaken
    /// for the answer of the new one.
    func discardStaleResponse() {
        lock.withLock { stashedResponse = nil }
    }

    func timeout(id: UUID) {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard pendingID == id, let continuation = pendingContinuation else { return nil }
            pendingContinuation = nil
            pendingID = nil
            return continuation
        }
        pending?.resume(throwing: USBCDCError.readFailed(error: 0))
    }

    /// Arms the router for a new connection.
    func restart() {
        lock.withLock {
            stopped = false
            stashedResponse = nil
        }
    }

    /// Stops the reader loop and fails any pending command.
    func stop() {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            stopped = true
            stashedResponse = nil
            let continuation = pendingContinuation
            pendingContinuation = nil
            pendingID = nil
            return continuation
        }
        pending?.resume(throwing: USBCDCError.notConnected)
    }
}

actor USBCDCService: USBCDCServiceProtocol {
    // MARK: - Properties

    private var fileDescriptor: Int32 = -1
    private var connectedDevice: USBDevice?
    private var isConnectedFlag: Bool = false
    private let broadcaster = DeviceEventBroadcaster()
    private let router = LineRouter()
    private var readerTask: Task<Void, Never>?
    private var notificationsStarted = false
#if canImport(Darwin)
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
#endif

    nonisolated var deviceEvents: AsyncStream<Void> {
        broadcaster.stream()
    }

    nonisolated var events: AsyncStream<String> {
        router.eventStream()
    }

    /// BSD path of the first native USB Serial JTAG port (ESP32-S3/C6).
    static let nativeJTAGPortPath = "/dev/cu.debug-console"
    
    // MARK: - Public API
    
    func enumerateDevices() async -> [USBDevice] {
        startMonitoring()
#if canImport(Darwin)
        return await Task {
            var devices: [USBDevice] = []
            var sawJTAGPort = false

            // Enumerate all BSD serial services: CDC-ACM adapters (CP210x,
            // CH340, FTDI, ...) and, on most systems, the native USB Serial
            // JTAG port (/dev/cu.debug-console) as well.
            var matchingDict: io_object_t = 0
            if let matching = IOServiceMatching(kIOSerialBSDServiceValue as String) as CFMutableDictionary? {
                if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &matchingDict) == KERN_SUCCESS,
                   matchingDict != 0 {
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

                        // The picker is for ESP32 boards. Skip unrelated
                        // serial devices (modems, Bluetooth SPP, ...); the
                        // native USB Serial JTAG port is always kept, even
                        // if its vendor lookup fails on some systems.
                        let isESP32 = (usbVendorID.map(USBDevice.isESP32Device) ?? false)
                            || (callout == Self.nativeJTAGPortPath)

                        let devicePath = callout ?? serialPath
                        if isESP32, let path = devicePath, isValidSerialPath(path) {
                            if path == Self.nativeJTAGPortPath {
                                sawJTAGPort = true
                            }
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
                }
            }

            // Fallback for systems whose IOKit enumeration does not surface
            // the USB Serial JTAG port, even though it exists as a BSD
            // serial device.
            let jtagPath = Self.nativeJTAGPortPath
            if !sawJTAGPort, FileManager.default.fileExists(atPath: jtagPath) {
                devices.append(USBDevice(
                    vendorID: 0x303A, // Espressif
                    productID: 0x1001, // USB Serial JTAG
                    serialNumber: nil,
                    deviceDescription: "USB JTAG/serial debug unit",
                    name: "ESP32-S3 USB Serial JTAG",
                    path: jtagPath
                ))
            }

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
        router.restart()
        startReader()
    }

    func disconnect() async {
        router.stop()
        readerTask?.cancel()
        readerTask = nil
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

        // Serialize commands: wait for any in-flight command to complete
        while router.hasPending {
            try await Task.sleep(for: .milliseconds(10))
            guard fileDescriptor >= 0 else { throw USBCDCError.notConnected }
        }

        // Drop any stale response from a previously timed-out command so it
        // cannot be mistaken for the answer of the new one.
        router.discardStaleResponse()

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

        // The reader loop completes the pending response with the next
        // non-event line; arm a timeout so callers never hang forever. A
        // response that arrives before the pending is armed below is stashed
        // by the router and consumed immediately, which closes the race
        // between the write and the arming.
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            router.registerPending(id: id, continuation: continuation)
            Task { [router] in
                try? await Task.sleep(for: .seconds(2))
                router.timeout(id: id)
            }
        }
    }

    // MARK: - Reader loop

    /// Continuously reads the serial port on a detached task and routes
    /// complete lines through the LineRouter. Uses poll() so the loop
    /// notices disconnection and cancellation promptly.
    private func startReader() {
        let fd = fileDescriptor
        let router = router
        readerTask = Task.detached(priority: .utility) {
            var buffer: [UInt8] = []
            buffer.reserveCapacity(256)
            var chunk = [UInt8](repeating: 0, count: 256)
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

            while !router.isStopped && !Task.isCancelled {
                let result = poll(&pollFD, 1, 100)
                if result < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if result == 0 { continue }
                if pollFD.revents & Int16(POLLIN) == 0 {
                    if pollFD.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break }
                    continue
                }

                let bytesRead = chunk.withUnsafeMutableBytes { raw -> Int in
                    guard let baseAddress = raw.baseAddress else { return 0 }
                    return read(fd, baseAddress, raw.count)
                }
                if bytesRead <= 0 {
                    if bytesRead < 0 && errno == EINTR { continue }
                    break
                }

                for byte in chunk.prefix(bytesRead) {
                    if byte == 0x0A {
                        let line = String(decoding: buffer, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer.removeAll(keepingCapacity: true)
                        if !line.isEmpty {
                            router.handleLine(line)
                        }
                    } else if byte != 0x0D {
                        if buffer.count < 1024 {
                            buffer.append(byte)
                        } else {
                            // Overflowing line: discard and resync on next newline
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
        }
    }
    
    deinit {
        router.stop()
        readerTask?.cancel()
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
