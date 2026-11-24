@testable import FlowKit
import simd
import XCTest

final class FlowKitTests: XCTestCase {
    func testSettingsAreClamped() {
        let s = FlowSettings(minSize: 0.9, maxSize: 0.01, speed: -1).validated
        XCTAssertLessThanOrEqual(s.minSize, s.maxSize)
        XCTAssertEqual(s.speed, FlowSettings.speedRange.lowerBound)
    }

    /// Files saved when the number of drops could be chosen still load.
    func testOldDropCountsAreNormalized() throws {
        let json = Data(#"{"dropCount":4,"minSize":0.2,"maxSize":0.3,"speed":1.5}"#.utf8)
        let s = try JSONDecoder().decode(FlowSettings.self, from: json).validated
        XCTAssertEqual(s, FlowSettings(minSize: 0.2, maxSize: 0.3, speed: 1.5))
    }

    func testSameSeedSameMotion() {
        let a = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 2, seed: 7)
        let b = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 2, seed: 7)
        for _ in 0 ..< 60 { a.step(1.0 / 30); b.step(1.0 / 30) }
        XCTAssertEqual(a.renderLobes().map(\.center), b.renderLobes().map(\.center))
    }

    /// Drops' centers stay on screen, move smoothly, and the first one never goes out.
    func testDropsStayOnScreen() {
        for seed in UInt64(1) ... 5 {
            let sim = FlowSimulation(settings: .default, aspect: 1.6, colorCount: 2, seed: seed)
            for _ in 0 ..< 30 * 300 {
                sim.step(1.0 / 30)
                for d in 0 ..< 4 {
                    let c = sim.center(of: d, at: sim.time)
                    XCTAssert((0 ... 1.6).contains(c.x) && (0 ... 1).contains(c.y))
                }
                XCTAssertGreaterThan(sim.lobe(0, of: 0, at: sim.time).amplitude, 0.6)
                XCTAssert(sim.renderLobes().allSatisfy { simd_length($0.velocity) < 0.6 && $0.amplitude >= 0 })
            }
        }
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
        XCTAssertEqual(MemoryLayout<FlowLobeUniform>.stride, 32)
        XCTAssertEqual(MemoryLayout<FlowUniforms>.stride, 192)
    }

    /// The same seed draws the same picture: nothing in the shaders depends on leftover state.
    func testStillsAreReproducible() throws {
        func still() throws -> Data {
            let image = try XCTUnwrap(FlowRenderer.still(palette: FlowPreset.all[0].palette, settings: .default, width: 64, height: 40, time: 3))
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        XCTAssertEqual(try still(), try still())
    }
}
