//
//  FlowConfiguration.swift
//  FlowKit
//

import Foundation

/// The colors of a Flow: a background, the liquid floating on it, one or more drop colors and
/// the halo the drops leave behind.
public struct FlowPalette: Codable, Hashable, Sendable {
    public var background: FlowColor
    /// The background liquid: a lighter or darker shade of the background.
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

    /// A shade of the background: lighter on dark backgrounds, darker on light ones.
    public static func defaultLiquid(for background: FlowColor) -> FlowColor {
        background.shifted(lightness: OKLCH(background).l < 0.55 ? 0.1 : -0.09)
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

/// How many drops there are, how big and how fast they move.
public struct FlowSettings: Codable, Hashable, Sendable {
    /// Number of drops.
    public var dropCount: Int
    /// Drop radius range, as a fraction of the screen's shorter side.
    public var minSize: Double
    public var maxSize: Double
    /// Motion speed multiplier; 1 is the watch face's pace.
    public var speed: Double

    public static let dropCountRange = 1 ... 4
    public static let sizeRange = 0.1 ... 0.5
    public static let speedRange = 0.2 ... 2.0

    public init(dropCount: Int = 1, minSize: Double = 0.3, maxSize: Double = 0.34, speed: Double = 1) {
        self.dropCount = dropCount
        self.minSize = minSize
        self.maxSize = maxSize
        self.speed = speed
    }

    public static let `default` = FlowSettings()

    /// Values clamped to the supported ranges (for settings read from disk).
    public var validated: FlowSettings {
        var s = self
        s.dropCount = min(max(dropCount, Self.dropCountRange.lowerBound), Self.dropCountRange.upperBound)
        s.minSize = min(max(minSize, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        s.maxSize = min(max(maxSize, s.minSize), Self.sizeRange.upperBound)
        s.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        return s
    }
}
