//
//  FlowPreset.swift
//  FlowKit
//

/// Built-in palettes, after the Flow watch face and the Home view: a background, a drop color
/// (plus a slightly darker second tone) and a separate halo color.
public struct FlowPreset: Hashable, Identifiable, Sendable {
    /// Stable name, also used as a storage key.
    public let name: String
    public let palette: FlowPalette

    public var id: String { name }

    init(_ name: String, background: UInt32, drop: UInt32, halo: UInt32) {
        let dropColor = FlowColor(hex: drop)
        self.name = name
        palette = FlowPalette(
            background: FlowColor(hex: background),
            drops: [dropColor, dropColor.shifted(lightness: -0.06)],
            halo: FlowColor(hex: halo)
        )
    }

    public static let all: [FlowPreset] = [
        FlowPreset("Sky", background: 0x0A0A0C, drop: 0xA0A4B8, halo: 0x6EC4F8),
        FlowPreset("Lime", background: 0x0A0A0A, drop: 0xC2C0BA, halo: 0xC6EE62),
        FlowPreset("Peach", background: 0x0A0A0A, drop: 0xF0C890, halo: 0xE48CEC),
        FlowPreset("Cocoa", background: 0x0B0B0B, drop: 0xA8805C, halo: 0xC848D8),
        FlowPreset("Coral", background: 0xCDBFB3, drop: 0xE05A58, halo: 0xE868D0),
        FlowPreset("Mint", background: 0x9CCCC2, drop: 0x5EBCEC, halo: 0x7A5CF0),
        FlowPreset("Lemon", background: 0xCFBFD1, drop: 0xE4F064, halo: 0xF07A38),
        FlowPreset("Meadow", background: 0xC6C48E, drop: 0x92DCF6, halo: 0x4CB848),
        FlowPreset("Berry", background: 0x4A1E48, drop: 0xC03CA0, halo: 0xE07ACB),
        FlowPreset("Purple", background: 0x7A5A92, drop: 0x2A2080, halo: 0xC840D8),
        FlowPreset("Amber", background: 0x5C2A12, drop: 0xB0441A, halo: 0xD9B48F),
        FlowPreset("Green", background: 0x14A85A, drop: 0x3A6EE8, halo: 0xC8E048),
    ]

    public static func named(_ name: String) -> FlowPreset? {
        all.first { $0.name == name }
    }
}
