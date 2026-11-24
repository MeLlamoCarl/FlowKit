//
//  FlowConfiguration.swift
//  FlowKit
//

import Foundation

/// The colors of a Flow: a background, the liquid floating on it, one or more drop colors and
/// the halo the drops leave behind.
public struct FlowPalette: Codable, Hashable, Sendable {
    public var background: FlowColor
    /// The background's second color, across the screen from the first.
    public var liquid: FlowColor
    /// Each drop takes one of these, in turn.
    public var drops: [FlowColor]
    public var halo: FlowColor

    public init(background: FlowColor, liquid: FlowColor? = nil, drops: [FlowColor], halo: FlowColor) {
        self.background = background
        self.liquid = liquid ?? Self.defaultLiquid(for: background)
        self.drops = drops.isEmpty ? [background.shifted(lightness: -0.2)] : drops
        self.halo = halo
    }

    /// The background's neighbour: lighter on dark backgrounds, darker on light ones, and a little
    /// further around the color wheel.
    public static func defaultLiquid(for background: FlowColor) -> FlowColor {
        var lch = OKLCH(background)
        lch.l += lch.l < 0.55 ? 0.1 : -0.09
        lch.h -= 0.45
        return lch.color
    }

    private enum CodingKeys: String, CodingKey { case background, liquid, drops, halo }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            background: c.decode(FlowColor.self, forKey: .background),
            liquid: c.decodeIfPresent(FlowColor.self, forKey: .liquid),
            drops: c.decode([FlowColor].self, forKey: .drops),
            halo: c.decode(FlowColor.self, forKey: .halo)
        )
    }
}

/// How big the drops are and how fast they move.
public struct FlowSettings: Codable, Hashable, Sendable {
    /// Number of drops; stored so files keep their format, always `standardDropCount` once validated.
    var dropCount: Int
    /// Drop radius range, as a fraction of the screen's shorter side.
    public var minSize: Double
    public var maxSize: Double
    /// Motion speed multiplier; 1 is the standard pace.
    public var speed: Double

    /// Flows are always made of this many drops, which merge, split and dissolve on their own.
    public static let standardDropCount = 2
    public static let sizeRange = 0.1 ... 0.5
    public static let speedRange = 0.2 ... 2.0

    public init(minSize: Double = 0.26, maxSize: Double = 0.36, speed: Double = 1) {
        dropCount = Self.standardDropCount
        self.minSize = minSize
        self.maxSize = maxSize
        self.speed = speed
    }

    public static let `default` = FlowSettings()

    /// Values clamped to the supported ranges (for settings read from disk).
    public var validated: FlowSettings {
        var s = self
        s.dropCount = Self.standardDropCount
        s.minSize = min(max(minSize, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        s.maxSize = min(max(maxSize, s.minSize), Self.sizeRange.upperBound)
        s.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        return s
    }
}
