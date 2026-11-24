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

    init(_ name: String, background: UInt32, liquid: UInt32? = nil, drop: UInt32, halo: UInt32) {
        let dropColor = FlowColor(hex: drop)
        self.name = name
        palette = FlowPalette(
            background: FlowColor(hex: background),
            liquid: liquid.map { FlowColor(hex: $0) },
            drops: [dropColor, dropColor.shifted(lightness: -0.03)],
            halo: FlowColor(hex: halo)
        )
    }

    public static let all: [FlowPreset] = [
        FlowPreset("Sky", background: 0x0A0A0C, drop: 0xA0A4B8, halo: 0x6EC4F8),
        FlowPreset("Lime", background: 0x0A0A0A, drop: 0xC2C0BA, halo: 0xC6EE62),
        FlowPreset("Peach", background: 0x0A0A0A, drop: 0xF0C890, halo: 0xE48CEC),
        FlowPreset("Cocoa", background: 0x0B0B0B, drop: 0xA8805C, halo: 0xC848D8),
        FlowPreset("Coral", background: 0xCDBFB3, drop: 0xE05A58, halo: 0xE868D0),
        FlowPreset("Mint", background: 0x93C5B9, liquid: 0x74BFA2, drop: 0x52A5E2, halo: 0x6C62DA),
        FlowPreset("Lemon", background: 0xCFBFD1, drop: 0xE4F064, halo: 0xF07A38),
        FlowPreset("Meadow", background: 0xC6C48E, drop: 0x92DCF6, halo: 0x4CB848),
        FlowPreset("Berry", background: 0x4A1E48, drop: 0xC03CA0, halo: 0xE07ACB),
        FlowPreset("Purple", background: 0x7A5A92, drop: 0x2A2080, halo: 0xC840D8),
        FlowPreset("Amber", background: 0x5C2A12, drop: 0xB0441A, halo: 0xD9B48F),
        FlowPreset("Green", background: 0x14A85A, drop: 0x3A6EE8, halo: 0xC8E048),
        FlowPreset("Sunset", background: 0xF0A818, liquid: 0xE2DC3C, drop: 0xF0486E, halo: 0xF2B4DC),
        FlowPreset("Lagoon", background: 0x7C6CE8, liquid: 0x62A4EA, drop: 0x0A84B0, halo: 0x58D098),
        FlowPreset("Reef", background: 0x4478F0, liquid: 0x1CD2F0, drop: 0x08BE80, halo: 0x86E848),
        FlowPreset("Aurora", background: 0x0B1230, liquid: 0x143A4C, drop: 0x6A4CE0, halo: 0x3CE8A8),
        FlowPreset("Ember", background: 0x120808, liquid: 0x3A0E10, drop: 0xFFC24A, halo: 0xF0401C),
        FlowPreset("Neon", background: 0x14082E, liquid: 0x2E0C5A, drop: 0x18D8F0, halo: 0xFF2CA0),
        FlowPreset("Orchid", background: 0xE8D4F4, liquid: 0xF8DCD8, drop: 0x9A4CE0, halo: 0xF48AC0),
        FlowPreset("Glacier", background: 0xDCEBF2, liquid: 0xB6D0F0, drop: 0x2C5CC8, halo: 0x7CDCE8),
        FlowPreset("Matcha", background: 0xEDE8CF, liquid: 0xC8DCA4, drop: 0x3C7A4A, halo: 0xA8D85C),
        FlowPreset("Apricot", background: 0xFCD8B4, liquid: 0xF8B8A8, drop: 0x2CA8A0, halo: 0xFFF0C8),
        FlowPreset("Graphite", background: 0x1A1C20, liquid: 0x33383F, drop: 0xE8EAEE, halo: 0x7C8794),
    ]

    public static func named(_ name: String) -> FlowPreset? {
        all.first { $0.name == name }
    }
}
