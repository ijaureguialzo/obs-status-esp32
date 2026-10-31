//
//  Color+Contrast.swift
//  Luminance and alpha-compositing helpers. Used to keep the LED indicator
//  content (icon, text) legible on top of any recording LED color.
//

import AppKit
import SwiftUI

extension Color {
    /// sRGB components in the 0...1 range, or `nil` when the color cannot be
    /// resolved to sRGB.
    var srgbComponents: (red: Double, green: Double, blue: Double, alpha: Double)? {
        NSColor(self).usingColorSpace(.sRGB).map {
            (
                red: Double($0.redComponent),
                green: Double($0.greenComponent),
                blue: Double($0.blueComponent),
                alpha: Double($0.alphaComponent)
            )
        }
    }

    /// WCAG 2.x relative luminance (0 = black, 1 = white). Colors that cannot
    /// be resolved to sRGB report white luminance, so callers fail toward
    /// dark content.
    var relativeLuminance: Double {
        guard let c = srgbComponents else { return 1 }
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// This color alpha-composited over `base`, as a fully opaque color.
    func composited(over base: Color) -> Color {
        guard let top = srgbComponents, let bottom = base.srgbComponents else {
            return self
        }
        let alpha = top.alpha
        func mix(_ top: Double, _ bottom: Double) -> Double {
            top * alpha + bottom * (1 - alpha)
        }
        return Color(
            .sRGB,
            red: mix(top.red, bottom.red),
            green: mix(top.green, bottom.green),
            blue: mix(top.blue, bottom.blue),
            opacity: 1
        )
    }

    /// White or black, whichever yields the higher WCAG contrast ratio
    /// against this color (the two are equal at a relative luminance of
    /// ≈ 0.179).
    var contrastingContentColor: Color {
        relativeLuminance < 0.179 ? .white : .black
    }
}
