//
//  FlowSimulation.swift
//  FlowKit
//

import Foundation
import simd

/// Moves the drops of a Flow. Coordinates are in "screen heights": y in 0...1, x in 0...aspect.
///
/// Each drop glides over the screen along a slow Lissajous curve, off its edges and back, and is
/// made of a few soft lobes that circle its center, drift apart and come back, and swell and
/// shrink. They merge where they meet, so the drop stretches, splits, melts together and, now and
/// then, dissolves and grows back. The dye that makes them visible is updated on the GPU (see
/// `FlowShaders`).
///
/// Everything here is a function of time, so it costs next to nothing.
public final class FlowSimulation {
    public private(set) var settings: FlowSettings
    public var aspect: Double {
        didSet { aspect = max(aspect, 0.1) }
    }
    private(set) var time: Double = 0

    /// What makes each drop move its own way.
    private struct Drop {
        /// Where in the size range it falls (0...1).
        var size: Double
        var phase: Double
    }
    private let drops: [Drop]
    private(set) var colorIndices: [Int] = []

    /// Drops (each gets one color channel in the dye texture).
    static let maxDrops = 4
    static let lobesPerDrop = 3

    // MARK: Parameters (static vars so the tuning tests can try others)

    /// Pace of the drops along their paths.
    static var wander = 0.13
    /// How far the drops' centers go: 1 is up to the edges.
    static var reach = 0.96
    /// Pace of the lobes' own motion.
    static var churn = 1.0

    public init(settings: FlowSettings, aspect: Double, colorCount: Int, seed: UInt64 = .random(in: 1 ... .max)) {
        self.settings = settings.validated
        self.aspect = max(aspect, 0.1)
        var rng = SeededRandom(seed: seed)
        let start = rng.next(in: 0 ... 100)
        drops = (0 ..< Self.maxDrops).map { _ in Drop(size: rng.next(in: 0 ... 1), phase: start + rng.next(in: 0 ... 1)) }
        update(settings: settings, colorCount: colorCount)
    }

    public func update(settings newSettings: FlowSettings, colorCount: Int) {
        settings = newSettings.validated
        colorIndices = (0 ..< Self.maxDrops).map { $0 % max(colorCount, 1) }
    }

    /// Advances by `dt` (real) seconds; returns the simulated time that passed.
    @discardableResult
    public func step(_ dt: Double) -> Double {
        let simulated = min(max(dt, 0), 1.0 / 15) * settings.speed // big gaps mustn't make drops jump
        time += simulated
        return simulated
    }

    // MARK: Drops

    func radius(of d: Int) -> Double {
        (settings.minSize + (settings.maxSize - settings.minSize) * drops[d].size) * min(aspect, 1)
    }

    func center(of d: Int, at time: Double) -> SIMD2<Double> {
        let t = time * Self.wander + Double(d) * 2.1 + drops[d].phase
        let ax = aspect / 2 * Self.reach, ay = 0.5 * Self.reach
        return SIMD2(
            aspect / 2 + ax * sin(t + 0.7) * (0.75 + 0.25 * sin(t * 0.37)),
            0.5 + ay * sin(t * 1.37 + 2.1) * (0.75 + 0.25 * cos(t * 0.29))
        )
    }

    struct Lobe {
        var center: SIMD2<Double>
        var radius: Double
        var amplitude: Double
    }

    /// Lobe `l` of drop `d` (0 is its main body, the others circle it).
    func lobe(_ l: Int, of d: Int, at time: Double) -> Lobe {
        let r = radius(of: d), base = center(of: d, at: time)
        let t = time * Self.churn + (drops[d].phase + Double(d) * 1.7) * 11
        // A drop fades now and then; the first one always leaves at least its halo.
        let breath = d == 0 ? 1.0 + 0.3 * sin(t * 0.17) : 0.75 + 0.6 * sin(t * 0.17 + Double(d))
        switch l {
        case 0:
            return Lobe(center: base, radius: r * (1.0 + 0.1 * sin(t * 0.31)), amplitude: max(breath, 0))
        case 1:
            let angle = t * 0.29 + 1.3 * sin(t * 0.13)
            let away = r * (0.75 + 0.35 * sin(t * 0.23 + 1))
            return Lobe(center: base + SIMD2(cos(angle), sin(angle)) * away, radius: r * 0.75,
                        amplitude: max(breath * (0.8 + 0.3 * sin(t * 0.37 + 2)), 0))
        default:
            // Wanders off on its own and comes back.
            let angle = -t * 0.21 + 1.7 * sin(t * 0.11 + 2)
            let away = r * (1.25 + 0.75 * sin(t * 0.19 + 3))
            return Lobe(center: base + SIMD2(cos(angle), sin(angle)) * away, radius: r * 0.65,
                        amplitude: max(0.7 + 0.6 * sin(t * 0.27 + 4), 0))
        }
    }

    // MARK: Render data

    func renderLobes() -> [FlowLobeUniform] {
        (0 ..< settings.dropCount).flatMap { d in
            (0 ..< Self.lobesPerDrop).map { l in
                let now = lobe(l, of: d, at: time)
                let e = 0.01
                let velocity = (lobe(l, of: d, at: time + e).center - lobe(l, of: d, at: time - e).center) / (2 * e)
                return FlowLobeUniform(center: SIMD2<Float>(now.center), velocity: SIMD2<Float>(velocity),
                                       radius: Float(now.radius), amplitude: Float(now.amplitude), drop: Int32(d))
            }
        }
    }

    /// Color of each drop, as its place in the palette.
    func color(of d: Int, in palette: FlowPalette) -> FlowColor {
        palette.drops[colorIndices[d] % palette.drops.count]
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
