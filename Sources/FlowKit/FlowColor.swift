//
//  FlowColor.swift
//  FlowKit
//

import CoreGraphics
import simd

/// An sRGB color (components 0...1). Codable so palettes can be stored as plain JSON.
public struct FlowColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        func unit(_ x: CGFloat) -> Double { min(max(Double(x), 0), 1) } // extended sRGB → sRGB
        self.init(red: unit(c[0]), green: unit(c[1]), blue: unit(c[2]))
    }

    var simd: SIMD4<Float> {
        SIMD4(Float(red), Float(green), Float(blue), 1)
    }
}

// MARK: - OKLab / OKLCH

/// Perceptual color space (Björn Ottosson's OKLab), used to derive shades and halos so that
/// "lighter" or "more saturated" looks the same for every hue.
struct OKLCH {
    var l: Double
    var c: Double
    var h: Double // radians

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    init(_ color: FlowColor) {
        func linear(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        self.init(l: L, c: hypot(A, B), h: atan2(B, A))
    }

    var color: FlowColor {
        let A = c * cos(h), B = c * sin(h)
        let L = l
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        func gamma(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        return FlowColor(
            red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076127010 * s)
        )
    }
}

extension FlowColor {
    /// The same hue, lighter or darker by `amount` of OKLab lightness.
    func shifted(lightness amount: Double) -> FlowColor {
        var lch = OKLCH(self)
        lch.l = min(max(lch.l + amount, 0), 1)
        return lch.color
    }
}

extension FlowColor {
    /// A mix of two colors in OKLab: `amount` 0 is this color, 1 is `other`.
    public func mixed(with other: FlowColor, amount: Double) -> FlowColor {
        let t = min(max(amount, 0), 1)
        let a = OKLCH(self), b = OKLCH(other)
        let ax = a.c * cos(a.h) * (1 - t) + b.c * cos(b.h) * t
        let ay = a.c * sin(a.h) * (1 - t) + b.c * sin(b.h) * t
        return OKLCH(l: a.l * (1 - t) + b.l * t, c: hypot(ax, ay), h: atan2(ay, ax)).color
    }
}

extension FlowPalette {
    /// A mix of two palettes (for transitions); drop colors are paired in turn.
    public func mixed(with other: FlowPalette, amount: Double) -> FlowPalette {
        let count = max(drops.count, other.drops.count)
        return FlowPalette(
            background: background.mixed(with: other.background, amount: amount),
            liquid: liquid.mixed(with: other.liquid, amount: amount),
            drops: (0 ..< count).map { drops[$0 % drops.count].mixed(with: other.drops[$0 % other.drops.count], amount: amount) },
            halo: halo.mixed(with: other.halo, amount: amount)
        )
    }
}
