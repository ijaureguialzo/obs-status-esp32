//
//  AppDelegateTests.swift
//  Unit tests for the app-termination cleanup: a connected ESP32 is
//  returned to its initial screen before the quit proceeds.
//

import AppKit
import Foundation
import XCTest

@testable import ObsStatus

@MainActor
final class AppDelegateTests: XCTestCase {
    private static let device = USBDevice(
        vendorID: 0x303A,
        productID: 0x1001,
        serialNumber: "TEST-SERIAL",
        name: "test-device",
        path: "/dev/cu.debug-console"
    )

    private static func makeViewModel(usb: FakeUSBCDCService) -> AppViewModel {
        AppViewModel(
            obsService: FakeOBSWebSocketService(),
            usbService: usb,
            settings: AppSettings(
                fileURL: URL.temporaryDirectory.appendingPathComponent(
                    "obs-status-test-\(UUID().uuidString).json")))
    }

    func testQuitsImmediatelyWithoutViewModel() {
        let delegate = AppDelegate()
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow)
    }

    func testQuitsImmediatelyWhenESPDisconnected() {
        let usb = FakeUSBCDCService()
        let delegate = AppDelegate()
        delegate.viewModel = Self.makeViewModel(usb: usb)

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow)
        XCTAssertEqual(usb.disconnectCount, 0)
    }

    func testReturnsBoardToInitialScreenBeforeQuit() async {
        let usb = FakeUSBCDCService()
        let viewModel = Self.makeViewModel(usb: usb)
        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true

        let delegate = AppDelegate()
        delegate.viewModel = viewModel
        let quit = expectation(description: "termination completes")
        delegate.finishTermination = { quit.fulfill() }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater)
        await fulfillment(of: [quit], timeout: 5)

        XCTAssertEqual(viewModel.espConnected, false)
        XCTAssertEqual(usb.disconnectCount, 1)
        XCTAssertTrue(
            usb.sentCommands.contains { $0.hasPrefix("SCENE:") },
            "The board must be sent an empty scene before the link closes")
    }

    func testRepeatedQuitDefersWithoutSecondCleanup() async {
        let usb = FakeUSBCDCService()
        usb.slowFail = true  // keep the first cleanup in flight
        let viewModel = Self.makeViewModel(usb: usb)
        viewModel.selectedDevice = Self.device
        viewModel.espConnected = true

        let delegate = AppDelegate()
        delegate.viewModel = viewModel
        var quitCount = 0
        let quit = expectation(description: "termination completes")
        quit.assertForOverFulfill = false
        delegate.finishTermination = {
            quitCount += 1
            quit.fulfill()
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater)
        // Second quit request while the cleanup is in flight.
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater)
        await fulfillment(of: [quit], timeout: 10)

        XCTAssertEqual(quitCount, 1, "Exactly one cleanup must run")
        XCTAssertEqual(usb.disconnectCount, 1)
        XCTAssertEqual(viewModel.espConnected, false)
    }
}
