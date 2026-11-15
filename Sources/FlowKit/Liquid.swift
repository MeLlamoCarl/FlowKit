//
//  Liquid.swift
//  FlowKit
//

import Foundation
import simd

/// How a body of liquid behaves.
struct LiquidParameters {
    /// Pressure stiffness (fraction of h moved per step per unit of density error).
    var stiffness: Double
    var nearStiffness: Double
    /// Viscosity (linear and quadratic), per second.
    var viscosityLinear: Double
    var viscosityQuadratic: Double
    /// Surface tension, per second²: pulls a body's outer particles toward its center, so it
    /// stays one rounded mass that squashes and springs back instead of spreading like water.
    var cohesion: Double
    /// Drag from the surrounding medium, per second.
    var drag: Double
}

/// Particles of one or more bodies of thick, cohesive liquid (each body a "group"), simulated with
/// Clavet, Beaudoin and Poulin's "Particle-based Viscoelastic Fluid Simulation" (double density
/// relaxation, the method behind many goo and lava-lamp simulations): pressure keeps the liquid
/// from compressing, near-pressure keeps particles apart, and the negative pressure at the surface
/// acts like surface tension. A viscosity term makes it thick; an extra cohesion keeps each body
/// together. The screen's edges contain it. Coordinates are in screen heights.
final class Liquid {
    /// Particle spacing at rest.
    let spacing: Double
    /// Interaction radius.
    let h: Double
    private let restDensity: Double

    // Particles, as parallel arrays for speed.
    private(set) var x: [Double] = []
    private(set) var y: [Double] = []
    private(set) var vx: [Double] = []
    private(set) var vy: [Double] = []
    private var px: [Double] = []
    private var py: [Double] = []
    /// Which body each particle belongs to.
    private(set) var group: [Int] = []
    /// Rest radius of each body.
    private(set) var radii: [Double] = []

    init(spacing: Double) {
        self.spacing = spacing
        h = spacing * 2.2
        // Density of an interior particle in a perfect hexagonal lattice: the rest density.
        var rho = 0.0
        let row = spacing * sqrt(3) / 2
        for j in -4 ... 4 {
            let offset = j.isMultiple(of: 2) ? 0 : spacing / 2
            for i in -5 ... 5 {
                let ox = Double(i) * spacing + offset, oy = Double(j) * row
                let r = sqrt(ox * ox + oy * oy)
                if r > 1e-9, r < h {
                    let q = 1 - r / h
                    rho += q * q
                }
            }
        }
        restDensity = rho
    }

    var count: Int { x.count }

    func removeAll() {
        x = []; y = []; vx = []; vy = []; px = []; py = []; group = []; radii = []
    }

    /// Adds a round body (a hexagonal lattice of particles), clamped to the screen.
    func addBody(center: SIMD2<Double>, radius: Double, aspect: Double) {
        let index = radii.count
        radii.append(radius)
        let row = spacing * sqrt(3) / 2
        var j = -Int(radius / row) - 1
        while Double(j) * row <= radius {
            let offset = j.isMultiple(of: 2) ? 0 : spacing / 2
            var i = -Int(radius / spacing) - 1
            while Double(i) * spacing <= radius {
                let ox = Double(i) * spacing + offset, oy = Double(j) * row
                if ox * ox + oy * oy <= radius * radius {
                    x.append(min(max(center.x + ox, 0.01), aspect - 0.01))
                    y.append(min(max(center.y + oy, 0.01), 0.99))
                    group.append(index)
                }
                i += 1
            }
            j += 1
        }
        vx = Array(repeating: 0, count: x.count)
        vy = vx
        px = x
        py = y
    }

    /// Center of mass of each body.
    func centers() -> [SIMD2<Double>] {
        var sums = [SIMD2<Double>](repeating: .zero, count: radii.count)
        var counts = [Double](repeating: 0, count: radii.count)
        for i in 0 ..< count {
            sums[group[i]] += SIMD2(x[i], y[i])
            counts[group[i]] += 1
        }
        return sums.indices.map { sums[$0] / max(counts[$0], 1) }
    }

    /// Mean velocity of each body.
    func velocities() -> [SIMD2<Double>] {
        var sums = [SIMD2<Double>](repeating: .zero, count: radii.count)
        var counts = [Double](repeating: 0, count: radii.count)
        for i in 0 ..< count {
            sums[group[i]] += SIMD2(vx[i], vy[i])
            counts[group[i]] += 1
        }
        return sums.indices.map { sums[$0] / max(counts[$0], 1) }
    }

    /// Advances by `dt` with `acceleration[g]` applied to every particle of body `g`.
    /// `cohesionScale[g]` scales body `g`'s surface tension (1 when omitted).
    func step(_ dt: Double, aspect: Double, parameters p: LiquidParameters, acceleration: [SIMD2<Double>],
              cohesionScale: [Double] = []) {
        let n = count
        guard n > 0 else { return }
        let h = self.h

        // Acceleration and drag.
        let damping = exp(-dt * p.drag)
        for i in 0 ..< n {
            let a = acceleration[group[i]]
            vx[i] = (vx[i] + a.x * dt) * damping
            vy[i] = (vy[i] + a.y * dt) * damping
        }

        // Cohesion: pull outer particles toward their body's center.
        let centers = centers()
        for i in 0 ..< n {
            let c = centers[group[i]]
            let dx = x[i] - c.x, dy = y[i] - c.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let inner = radii[group[i]] * 0.55
            guard dist > inner else { continue }
            let scale = group[i] < cohesionScale.count ? cohesionScale[group[i]] : 1
            let pull = p.cohesion * scale * (dist - inner) * dt / dist
            vx[i] -= dx * pull
            vy[i] -= dy * pull
        }

        // Viscosity: damp the approaching velocity of neighbours.
        let grid = SpatialGrid(x: x, y: y, cell: h)
        grid.forEachPair(x: x, y: y, radius: h) { i, j, dx, dy, r in
            let q = r / h
            let nx = dx / r, ny = dy / r
            let u = (vx[i] - vx[j]) * nx + (vy[i] - vy[j]) * ny
            guard u > 0 else { return }
            let impulse = dt * (1 - q) * (p.viscosityLinear * u + p.viscosityQuadratic * u * u) * 0.5
            vx[i] -= impulse * nx; vy[i] -= impulse * ny
            vx[j] += impulse * nx; vy[j] += impulse * ny
        }

        // Predict positions.
        for i in 0 ..< n {
            px[i] = x[i]; py[i] = y[i]
            x[i] += vx[i] * dt
            y[i] += vy[i] * dt
        }

        // Double density relaxation.
        let relaxGrid = SpatialGrid(x: x, y: y, cell: h)
        var density = [Double](repeating: 0, count: n)
        var nearDensity = [Double](repeating: 0, count: n)
        relaxGrid.forEachPair(x: x, y: y, radius: h) { i, j, _, _, r in
            let q = 1 - r / h
            let q2 = q * q, q3 = q2 * q
            density[i] += q2; density[j] += q2
            nearDensity[i] += q3; nearDensity[j] += q3
        }
        let rest = restDensity
        relaxGrid.forEachPair(x: x, y: y, radius: h) { i, j, dx, dy, r in
            let q = 1 - r / h
            let pressure = p.stiffness * ((density[i] - rest) + (density[j] - rest)) * 0.5
            let near = p.nearStiffness * (nearDensity[i] + nearDensity[j]) * 0.5
            let d = (pressure * q + near * q * q) * h * 0.25
            let nx = dx / r, ny = dy / r
            x[i] -= d * nx; y[i] -= d * ny
            x[j] += d * nx; y[j] += d * ny
        }

        // Screen edges: the liquid stops there.
        let m = 0.004
        for i in 0 ..< n {
            x[i] = min(max(x[i], m), aspect - m)
            y[i] = min(max(y[i], m), 1 - m)
        }

        // Velocities from the corrected positions.
        for i in 0 ..< n {
            vx[i] = (x[i] - px[i]) / dt
            vy[i] = (y[i] - py[i]) / dt
        }
    }
}

/// Uniform grid for neighbour queries.
struct SpatialGrid {
    let cell: Double
    let columns: Int
    let rows: Int
    /// Particle indices sorted by cell, and where each cell's run starts.
    var order: [Int]
    var starts: [Int]

    init(x: [Double], y: [Double], cell: Double) {
        self.cell = cell
        let maxX = x.max() ?? 0, maxY = y.max() ?? 0
        columns = Int(maxX / cell) + 2
        rows = Int(maxY / cell) + 2
        var counts = [Int](repeating: 0, count: columns * rows + 1)
        var cells = [Int](repeating: 0, count: x.count)
        for i in x.indices {
            let c = min(max(Int(x[i] / cell), 0), columns - 1) + min(max(Int(y[i] / cell), 0), rows - 1) * columns
            cells[i] = c
            counts[c + 1] += 1
        }
        for c in 1 ..< counts.count { counts[c] += counts[c - 1] }
        starts = counts
        var fill = counts
        order = [Int](repeating: 0, count: x.count)
        for i in x.indices {
            order[fill[cells[i]]] = i
            fill[cells[i]] += 1
        }
    }

    /// Calls `body(i, j, dx, dy, r)` once per pair closer than `radius` (dx, dy from i to j).
    func forEachPair(x: [Double], y: [Double], radius: Double, _ body: (Int, Int, Double, Double, Double) -> Void) {
        let r2 = radius * radius
        for cy in 0 ..< rows {
            for cx in 0 ..< columns {
                let c = cx + cy * columns
                let a0 = starts[c], a1 = starts[c + 1]
                guard a0 < a1 else { continue }
                // This cell and the four "forward" neighbours, so each pair is seen once.
                for (ox, oy) in [(0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                    let nx = cx + ox, ny = cy + oy
                    guard nx >= 0, nx < columns, ny < rows else { continue }
                    let n = nx + ny * columns
                    let b0 = starts[n], b1 = starts[n + 1]
                    for a in a0 ..< a1 {
                        let i = order[a]
                        for b in (n == c ? a + 1 : b0) ..< b1 {
                            let j = order[b]
                            let dx = x[j] - x[i], dy = y[j] - y[i]
                            let d2 = dx * dx + dy * dy
                            if d2 < r2, d2 > 1e-14 {
                                body(i, j, dx, dy, d2.squareRoot())
                            }
                        }
                    }
                }
            }
        }
    }
}
