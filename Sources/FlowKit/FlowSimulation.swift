//
//  FlowSimulation.swift
//  FlowKit
//

import Foundation
import simd

/// Moves the liquids of a Flow. Coordinates are in "screen heights": y in 0...1, x in 0...aspect.
///
/// The drops are `Liquid` bodies moving through the background liquid that fills the screen
/// (simulated on the GPU as a flow field, see `FlowShaders`).
///
/// Each drop is drawn toward an attractor gliding over the screen along a slow Lissajous curve,
/// as if someone were tilting the screen (the Flow watch face moves its orb as the wrist moves):
/// it sweeps around in arcs and, now and then, leans on an edge and squashes.
public final class FlowSimulation {
    public private(set) var settings: FlowSettings
    public var aspect: Double {
        didSet { aspect = max(aspect, 0.1) }
    }
    private(set) var time: Double = 0
    private var rng: SeededRandom
    /// Offsets the attractors' paths, so each seed moves differently.
    private var seedPhase = 0.0

    let drops = Liquid(spacing: FlowSimulation.spacing)
    private(set) var colorIndices: [Int] = []

    /// Particle spacing of the drops, in screen heights.
    static let spacing = 0.026
    /// Interaction radius of the drops' particles.
    static let h = spacing * 2.2
    /// Drops (each gets one color channel in the density texture).
    static let maxDrops = 4

    // MARK: Parameters (static vars so the tuning tests can try others)

    static var stiffness = 0.15
    static var nearStiffness = 0.2
    static var viscosityLinear = 1.5
    static var viscosityQuadratic = 8.0
    /// Pull toward the attractor, screen heights per second².
    static var gravity = 0.75
    static var cohesion = 6.0
    static var drag = 0.8
    /// Pace of the attractors along their paths.
    static var wander = 0.14
    /// How far toward the edges the attractors go: 0 keeps the drop clear of them, 1 brings its
    /// center to the edge (the drop then presses hard into it).
    static var reach = 1.05
    /// Surface tension left when a drop leans on an edge (fraction of `cohesion`): the drop holds
    /// its round shape in the open and gives way, flattening and spreading, against the edges.
    static var wallSoftness = 0.15
    private static let substep = 1.0 / 120

    private var dropParameters: LiquidParameters {
        LiquidParameters(stiffness: Self.stiffness, nearStiffness: Self.nearStiffness,
                         viscosityLinear: Self.viscosityLinear, viscosityQuadratic: Self.viscosityQuadratic,
                         cohesion: Self.cohesion, drag: Self.drag)
    }

    public init(settings: FlowSettings, aspect: Double, colorCount: Int, seed: UInt64 = .random(in: 1 ... .max)) {
        self.settings = settings.validated
        self.aspect = max(aspect, 0.1)
        rng = SeededRandom(seed: seed)
        seedPhase = rng.next(in: 0 ... 100)
        respawn(colorCount: colorCount)
    }

    /// Applies new settings. Changing the number or size of drops pours them in anew.
    public func update(settings newSettings: FlowSettings, colorCount: Int) {
        let newSettings = newSettings.validated
        let reshape = newSettings.dropCount != settings.dropCount
            || newSettings.minSize != settings.minSize || newSettings.maxSize != settings.maxSize
        settings = newSettings
        if reshape { respawn(colorCount: colorCount) }
        colorIndices = (0 ..< drops.radii.count).map { $0 % max(colorCount, 1) }
    }

    private func respawn(colorCount: Int) {
        let s = settings
        let count = min(s.dropCount, Self.maxDrops)
        drops.removeAll()
        let scale = min(aspect, 1)
        for d in 0 ..< count {
            let radius = rng.next(in: s.minSize ... max(s.maxSize, s.minSize + 0.0001)) * scale
            let center = SIMD2(aspect * (Double(d) + 0.5) / Double(count), rng.next(in: 0.4 ... 0.6))
            drops.addBody(center: center, radius: radius, aspect: aspect)
        }
        colorIndices = (0 ..< count).map { $0 % max(colorCount, 1) }
    }

    // MARK: Compatibility for tests and the renderer

    var x: [Double] { drops.x }
    var y: [Double] { drops.y }
    var dropRadii: [Double] { drops.radii }

    // MARK: Stepping

    public func step(_ dt: Double) {
        let total = min(max(dt, 0), 1.0 / 15) * settings.speed // big gaps mustn't make drops jump
        var left = total
        while left > 1e-6 {
            let h = min(left, Self.substep)
            substep(h)
            left -= h
        }
    }

    /// Where drop `d` is being drawn to: a point gliding over the screen along a slow Lissajous
    /// curve (its own phases per drop), reaching close enough to the edges now and then that the
    /// drop leans on one and squashes.
    func attractor(for d: Int) -> SIMD2<Double> {
        let r = drops.radii[d]
        let t = time * Self.wander + Double(d) * 2.1 + seedPhase
        let ax = max(aspect / 2 - r * (1 - Self.reach), 0.01), ay = max(0.5 - r * (1 - Self.reach), 0.01)
        return SIMD2(
            aspect / 2 + ax * sin(t * 1.0 + 0.7) * (0.75 + 0.25 * sin(t * 0.37)),
            0.5 + ay * sin(t * 1.37 + 2.1) * (0.75 + 0.25 * cos(t * 0.29))
        )
    }

    private func substep(_ dt: Double) {
        time += dt

        // Drops: toward their attractors (weaker when close).
        let dropCenters = drops.centers()
        let pulls = dropCenters.indices.map { d -> SIMD2<Double> in
            let toward = attractor(for: d) - dropCenters[d]
            let distance = simd_length(toward)
            guard distance > 1e-6 else { return .zero }
            return toward / distance * (Self.gravity * min(distance / 0.15, 1))
        }
        let softening = dropCenters.indices.map { d -> Double in
            let c = dropCenters[d], r = drops.radii[d]
            let gap = min(c.x, aspect - c.x, c.y, 1 - c.y) / max(r, 1e-6) // 1 = touching an edge
            let t = min(max((gap - 0.8) / 0.6, 0), 1)
            let near = 1 - t * t * (3 - 2 * t)
            return 1 - (1 - Self.wallSoftness) * near
        }
        drops.step(dt, aspect: aspect, parameters: dropParameters, acceleration: pulls, cohesionScale: softening)
    }

    // MARK: Render data

    /// Drop particles for the density splat: (x, y, drop index, 0).
    func renderParticles() -> [SIMD4<Float>] {
        (0 ..< drops.count).map { SIMD4(Float(drops.x[$0]), Float(drops.y[$0]), Float(drops.group[$0]), 0) }
    }

    /// Per-drop data: color, center and velocity (from its particles) and rest radius.
    func renderDrops(palette: FlowPalette) -> [FlowDropUniform] {
        let centers = drops.centers(), velocities = drops.velocities()
        return drops.radii.indices.map { d in
            let color = palette.drops[colorIndices[d] % palette.drops.count]
            return FlowDropUniform(
                color: color.simd,
                center: SIMD2<Float>(centers[d]),
                velocity: SIMD2<Float>(velocities[d]),
                radius: Float(drops.radii[d])
            )
        }
    }
}

/// Small deterministic generator (SplitMix64), so a seed reproduces the same motion.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
