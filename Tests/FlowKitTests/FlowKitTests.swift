@testable import FlowKit
import XCTest

final class FlowKitTests: XCTestCase {
    func testSettingsAreClamped() {
        let s = FlowSettings(dropCount: 99, minSize: 0.9, maxSize: 0.01, speed: -1).validated
        XCTAssertEqual(s.dropCount, FlowSettings.dropCountRange.upperBound)
        XCTAssertLessThanOrEqual(s.minSize, s.maxSize)
        XCTAssertEqual(s.speed, FlowSettings.speedRange.lowerBound)
    }

    func testSameSeedSameMotion() {
        let a = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 2, seed: 7)
        let b = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 2, seed: 7)
        for _ in 0 ..< 60 { a.step(1.0 / 30); b.step(1.0 / 30) }
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, b.y)
    }

    /// The liquid stays on screen, doesn't blow up and holds together as one drop.
    func testLiquidStaysTogether() {
        let sim = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 1, seed: 3)
        let count = sim.x.count
        XCTAssertGreaterThan(count, 100)
        for _ in 0 ..< 30 * 20 { sim.step(1.0 / 30) }
        XCTAssertEqual(sim.x.count, count)
        XCTAssert(sim.x.allSatisfy { (0 ... 1.6).contains($0) } && sim.y.allSatisfy { (0 ... 1).contains($0) })
        // Nearly every particle has a neighbour close by (no spray of loose droplets).
        let h = FlowSimulation.h
        var lonely = 0
        for i in 0 ..< count {
            var neighbours = 0
            for j in 0 ..< count where j != i {
                let dx = sim.x[j] - sim.x[i], dy = sim.y[j] - sim.y[i]
                if dx * dx + dy * dy < h * h { neighbours += 1 }
            }
            if neighbours < 2 { lonely += 1 }
        }
        XCTAssertLessThan(Double(lonely) / Double(count), 0.03)
    }

    func testOKLabRoundTrip() {
        let c = FlowColor(hex: 0x7A5A92)
        let back = OKLCH(c).color
        XCTAssertEqual(c.red, back.red, accuracy: 0.002)
        XCTAssertEqual(c.green, back.green, accuracy: 0.002)
        XCTAssertEqual(c.blue, back.blue, accuracy: 0.002)
    }

    func testRendersAnImage() throws {
        let renderer = try XCTUnwrap(FlowRenderer(palette: FlowPreset.all[0].palette, settings: .default, seed: 1))
        renderer.advance(by: 1, aspect: 1.6)
        let image = try XCTUnwrap(renderer.image(width: 64, height: 40))
        XCTAssertEqual(image.width, 64)
    }

    func testUniformLayoutsMatchTheShader() {
        XCTAssertEqual(MemoryLayout<FlowDropUniform>.stride, 48)
        XCTAssertEqual(MemoryLayout<FlowUniforms>.stride, 144)
    }

    /// Real frames come at uneven intervals (display link jitter, dropped frames).
    func testUnevenFramesStayStable() {
        let sim = FlowSimulation(settings: FlowSettings(dropCount: 2, minSize: 0.2, maxSize: 0.3, speed: 1.7),
                                 aspect: 1.6, colorCount: 2, seed: 5)
        var rng = SeededRandom(seed: 9)
        for _ in 0 ..< 3000 {
            sim.step(rng.next(in: 0.000001 ... 0.05))
        }
        XCTAssertTrue(sim.x.allSatisfy(\.isFinite) && sim.y.allSatisfy(\.isFinite))
        XCTAssertTrue(sim.x.allSatisfy { (0 ... 1.6).contains($0) } && sim.y.allSatisfy { (0 ... 1).contains($0) })
    }
}
