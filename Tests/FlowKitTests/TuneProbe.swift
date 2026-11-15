@testable import FlowKit
import XCTest

/// Run with FLOW_TUNE="gravity,cohesion,viscL,viscQ,reach,wander" to measure motion and deformation.
final class TuneProbe: XCTestCase {
    func testTune() throws {
        guard let spec = ProcessInfo.processInfo.environment["FLOW_TUNE"] else { throw XCTSkip() }
        let v = spec.split(separator: ",").map { Double($0)! }
        FlowSimulation.gravity = v[0]; FlowSimulation.cohesion = v[1]
        FlowSimulation.viscosityLinear = v[2]; FlowSimulation.viscosityQuadratic = v[3]
        FlowSimulation.reach = v[4]; FlowSimulation.wander = v[5]
        if v.count > 6 { FlowSimulation.wallSoftness = v[6] }
        let sim = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 1, seed: 3)
        let n = Double(sim.x.count)
        var prev: (Double, Double)?
        var speeds: [Double] = [], ratios: [Double] = [], nearWall: [Double] = [], open: [Double] = []
        let r0 = sim.dropRadii[0]
        for t in 1 ... 30 * 60 {
            sim.step(1.0 / 30)
            guard t % 3 == 0 else { continue }
            let cx = sim.x.reduce(0, +) / n, cy = sim.y.reduce(0, +) / n
            if let p = prev { speeds.append(hypot(cx - p.0, cy - p.1) * 10) }
            prev = (cx, cy)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for i in sim.x.indices {
                let dx = sim.x[i] - cx, dy = sim.y[i] - cy
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
            let tr = (sxx + syy) / 2, det = sqrt(max(tr * tr - (sxx * syy - sxy * sxy), 0))
            let ratio = sqrt((tr - det) / (tr + det)) // minor/major axis
            ratios.append(ratio)
            let gap = min(cx, 1.6 - cx, cy, 1 - cy) / r0
            if gap < 1.05 { nearWall.append(ratio) } else if gap > 1.35 { open.append(ratio) }
        }
        let sorted = ratios.sorted()
        func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        print(String(format: "TUNE %@ | speed avg=%.3f max=%.2f | axes avg=%.2f p10=%.2f min=%.2f | wall %.2f (%d) open %.2f (%d)",
                     spec, avg(speeds), speeds.max()!, avg(ratios), sorted[sorted.count / 10], sorted.first!,
                     nearWall.isEmpty ? 0 : avg(nearWall), nearWall.count, open.isEmpty ? 0 : avg(open), open.count))
    }
}
