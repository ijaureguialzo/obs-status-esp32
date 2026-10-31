//
//  ColorContrastTests.swift
//  Unit tests for the luminance / contrast helpers that keep the LED
//  indicator content legible on top of any recording LED color.
//

import SwiftUI
import XCTest

@testable import ObsStatus

final class ColorContrastTests: XCTestCase {
    // MARK: - Luminance

    func testBlackLuminanceIsZero() {
        let black = Color(.sRGB, red: 0, green: 0, blue: 0)
        XCTAssertEqual(black.relativeLuminance, 0, accuracy: 0.001)
    }

    func testWhiteLuminanceIsOne() {
        let white = Color(.sRGB, red: 1, green: 1, blue: 1)
        XCTAssertEqual(white.relativeLuminance, 1, accuracy: 0.001)
    }

    func testDarkRedLuminanceIsBelowThreshold() {
        // #370000: the user-reported unreadable case.
        let darkRed = Color(.sRGB, red: 0x37 / 255.0, green: 0, blue: 0)
        XCTAssertLessThan(darkRed.relativeLuminance, 0.179)
    }

    // MARK: - Content color selection

    func testDarkRedBackgroundYieldsWhiteContent() {
        let darkRed = Color(.sRGB, red: 0x37 / 255.0, green: 0, blue: 0)
        assertContentColor(darkRed.contrastingContentColor, is: .white)
    }

    func testWhiteBackgroundYieldsBlackContent() {
        let white = Color(.sRGB, red: 1, green: 1, blue: 1)
        assertContentColor(white.contrastingContentColor, is: .black)
    }

    func testDefaultRecordingGreenYieldsBlackContent() {
        assertContentColor(LEDColor.recordingDefault.color.contrastingContentColor, is: .black)
    }

    // MARK: - Alpha compositing (the semi-transparent idle fill)

    func testIdleFillOverLightWindowKeepsBlackContent() {
        let idle = Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 0.25)
        let light = Color(.sRGB, red: 0.925, green: 0.925, blue: 0.929, opacity: 1)
        assertContentColor(idle.composited(over: light).contrastingContentColor, is: .black)
    }

    func testIdleFillOverDarkWindowYieldsWhiteContent() {
        let idle = Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 0.25)
        let dark = Color(.sRGB, red: 0.118, green: 0.118, blue: 0.118, opacity: 1)
        assertContentColor(idle.composited(over: dark).contrastingContentColor, is: .white)
    }

    func testOpaqueColorCompositedOverAnyBaseIsUnchanged() {
        let darkRed = Color(.sRGB, red: 0x37 / 255.0, green: 0, blue: 0)
        let light = Color(.sRGB, red: 0.925, green: 0.925, blue: 0.929, opacity: 1)
        let composited = darkRed.composited(over: light)
        assertContentColor(composited.contrastingContentColor, is: .white)
    }

    // MARK: - Helpers

    private func assertContentColor(
        _ actual: Color,
        is expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let a = actual.srgbComponents, let e = expected.srgbComponents else {
            XCTFail("Could not resolve color to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(a.red, e.red, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.green, e.green, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.blue, e.blue, accuracy: 0.01, file: file, line: line)
    }
}
