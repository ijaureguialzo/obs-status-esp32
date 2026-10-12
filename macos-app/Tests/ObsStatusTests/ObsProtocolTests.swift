//
//  ObsProtocolTests.swift
//  Unit tests for the text protocol models used between macOS and ESP32.
//

import SwiftUI
import XCTest

@testable import ObsStatus

final class ObsCommandTests: XCTestCase {
    func testLineTermination() {
        XCTAssertEqual(ObsCommand.ledOn.lineTerminated, "LED_ON\n")
        XCTAssertEqual(ObsCommand.ledOff.lineTerminated, "LED_OFF\n")
        XCTAssertEqual(ObsCommand.blinkFast.lineTerminated, "BLINK_FAST\n")
        XCTAssertEqual(ObsCommand.blinkSlow.lineTerminated, "BLINK_SLOW\n")
        XCTAssertEqual(ObsCommand.status.lineTerminated, "STATUS\n")
    }

    func testLedOnWithColor() {
        let command = ObsCommand.ledOn(color: LEDColor(red: 255, green: 128, blue: 0))
        XCTAssertEqual(command, "LED_ON:255,128,0\n")
    }

    func testLedOnWithColorClampsToByteRange() {
        let command = ObsCommand.ledOn(color: LEDColor(red: 0, green: 0, blue: 255))
        XCTAssertEqual(command, "LED_ON:0,0,255\n")
    }

    func testSceneCommand() {
        XCTAssertEqual(ObsCommand.scene(name: "Main Scene"), "SCENE:Main Scene\n")
    }

    func testSceneCommandSanitizesLineBreaks() {
        XCTAssertEqual(ObsCommand.scene(name: "Main\nScene\r2"), "SCENE:Main Scene 2\n")
    }

    func testSceneCommandWithEmptyName() {
        XCTAssertEqual(ObsCommand.scene(name: ""), "SCENE:\n")
    }

    func testSceneCommandKeepsUTF8() {
        XCTAssertEqual(ObsCommand.scene(name: "Escena 日本語"), "SCENE:Escena 日本語\n")
    }

    func testSceneNameIsTruncatedToTheDisplayBudget() {
        let longName = String(repeating: "a", count: 200)
        XCTAssertEqual(
            ObsCommand.scene(name: longName), "SCENE:\(String(repeating: "a", count: 95))\n")
    }

    func testSceneNameAtTheBudgetIsUnchanged() {
        let exact = String(repeating: "b", count: 95)
        XCTAssertEqual(ObsCommand.scene(name: exact), "SCENE:\(exact)\n")
    }

    func testMultibyteSceneFitsTheWireBudgetOnACharacterBoundary() {
        // 95 CJK characters are 285 bytes (> 121); the result must fit the
        // 121-byte line budget, end on a character boundary, and stay valid
        // UTF-8 (no U+FFFD).
        let cjk = String(repeating: "日", count: 95)
        let command = ObsCommand.scene(name: cjk)
        let payload = command.dropFirst("SCENE:".count).dropLast()  // strip prefix + newline
        let payloadBytes = Array(payload.utf8)
        XCTAssertLessThanOrEqual(payloadBytes.count, 121)
        XCTAssertFalse(String(payload).contains("\u{FFFD}"))
        // 121 is not a multiple of 3, so one boundary back: 120 bytes = 40 chars
        XCTAssertEqual(payloadBytes.count, 120)
        XCTAssertEqual(String(payload), String(repeating: "日", count: 40))
    }

    func testAuthCommand() {
        XCTAssertEqual(
            ObsCommand.auth(secret: "abcd1234ef56abcd1234ef56abcd1234"),
            "AUTH:abcd1234ef56abcd1234ef56abcd1234\n")
    }

    func testAuthResponses() {
        XCTAssertEqual(ObsResponse.errorAuth, "ERROR: AUTH_FAILED")
        XCTAssertTrue(ObsResponse.isErrorResponse(ObsResponse.errorAuth))
        XCTAssertFalse(ObsResponse.isErrorResponse(ObsResponse.ok))
    }
}

final class ObsEventTests: XCTestCase {
    func testParseTogglePause() {
        XCTAssertEqual(ObsEvent.parse("EVENT:TOGGLE_PAUSE"), .togglePause)
    }

    func testParseTrimsLineEnding() {
        XCTAssertEqual(ObsEvent.parse("EVENT:TOGGLE_PAUSE\r\n"), .togglePause)
    }

    func testParseIgnoresCommandResponses() {
        XCTAssertNil(ObsEvent.parse("OK"))
        XCTAssertNil(ObsEvent.parse("STATUS:LED=ON|USB=CONNECTED|ERROR=0"))
        XCTAssertNil(ObsEvent.parse("ERROR: UNKNOWN_COMMAND"))
    }

    func testEventLinesSharePrefix() {
        XCTAssertTrue(ObsEvent.togglePause.rawValue.hasPrefix(ObsEvent.linePrefix))
    }
}

final class LEDColorTests: XCTestCase {
    func testRecordingDefaultIsGreen() {
        XCTAssertEqual(LEDColor.recordingDefault, LEDColor(red: 0, green: 255, blue: 0))
    }

    func testInitFromSwiftUIColor() {
        // SwiftUI's .red is the dynamic system red, not pure sRGB red.
        let red = LEDColor(color: .red)
        XCTAssertGreaterThan(red.red, 200)
        XCTAssertLessThan(red.green, 100)
        XCTAssertLessThan(red.blue, 100)
    }

    func testColorPropertyRoundTrip() {
        let color = LEDColor(red: 10, green: 20, blue: 30)
        let roundTripped = LEDColor(color: color.color)
        XCTAssertEqual(roundTripped.red, 10)
        XCTAssertEqual(roundTripped.green, 20)
        XCTAssertEqual(roundTripped.blue, 30)
    }
}

final class ObsProtocolUtilTests: XCTestCase {
    func testErrorDetection() {
        XCTAssertTrue(ObsProtocolUtil.isErrorResponse("ERROR: UNKNOWN_COMMAND"))
        XCTAssertTrue(ObsProtocolUtil.isErrorResponse("ERROR: INVALID_FORMAT"))
        XCTAssertFalse(ObsProtocolUtil.isErrorResponse("OK"))
        XCTAssertFalse(ObsProtocolUtil.isErrorResponse("STATUS:LED=ON|USB=CONNECTED|ERROR=0"))
    }
}
