//
//  FlowRenderer.swift
//  FlowKit
//

import CoreGraphics
import Metal
import MetalKit
import QuartzCore

/// Draws a Flow with Metal, into an `MTKView` (as its delegate) or an offscreen image.
///
/// Each frame the dye is updated and the picture is composed from it. The dye texture has a fixed
/// height, independent of the output size: it's smooth, so a small buffer scaled up looks the same
/// and costs little.
public final class FlowRenderer: NSObject {
    public let device: MTLDevice
    private let dyePipeline: MTLRenderPipelineState
    private let flowPipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private let sampler: MTLSamplerState
    public let simulation: FlowSimulation

    /// The palette being shown, or faded to.
    public private(set) var palette: FlowPalette
    /// Palette fade: from this one to `palette`, starting at `transitionStart`.
    private var transitionFrom: FlowPalette?
    private var transitionStart: CFTimeInterval = 0
    private var transitionDuration: Double = 0
    private var dye: [MTLTexture] = []
    private var lastTimestamp: CFTimeInterval?
    private let seed: Float
    /// Changes every frame, so the grain flickers.
    private var grainSeed: UInt32 = 0
    /// Grain strength (0 disables it).
    public var grain: Float = 0.01
    /// Advance the simulation on each draw; off for a still picture.
    public var isAnimating = true

    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private static let dyeHeight = 270

    public init?(palette: FlowPalette, settings: FlowSettings, aspect: Double = 16 / 9,
                 seed: UInt64 = .random(in: 1 ... .max), device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: flowShaderSource, options: nil)
            func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "flowVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            dyePipeline = try pipeline("dyeFragment", .rgba16Float)
            flowPipeline = try pipeline("flowFragment", Self.pixelFormat)
        } catch {
            print("FlowKit: couldn't build the shaders:", error)
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.sampler = sampler
        self.palette = palette
        self.seed = Float(seed % 1000) / 20
        simulation = FlowSimulation(settings: settings, aspect: aspect, colorCount: palette.drops.count, seed: seed)
        super.init()
        setPalette(palette)
    }

    /// Shows a new palette, fading to it over `transition` seconds (while animating).
    public func setPalette(_ palette: FlowPalette, transition: Double = 0) {
        transitionFrom = transition > 0 && isAnimating ? shownPalette() : nil
        transitionStart = CACurrentMediaTime()
        transitionDuration = transition
        self.palette = palette
        simulation.update(settings: simulation.settings, colorCount: palette.drops.count)
    }

    /// The palette on screen right now (mid-fade during a transition).
    private func shownPalette() -> FlowPalette {
        guard let from = transitionFrom else { return palette }
        let t = (CACurrentMediaTime() - transitionStart) / max(transitionDuration, 1e-6)
        guard t < 1 else {
            transitionFrom = nil
            return palette
        }
        return from.mixed(with: palette, amount: t * t * (3 - 2 * t))
    }

    public func setSettings(_ settings: FlowSettings) {
        simulation.update(settings: settings, colorCount: palette.drops.count)
    }

    /// Runs the motion and the dye forward by `seconds` at once (in small steps), e.g. to start
    /// mid-motion or before taking a still picture.
    public func advance(by seconds: Double, aspect: Double? = nil) {
        if let aspect { simulation.aspect = aspect }
        guard let buffer = queue.makeCommandBuffer() else { return }
        var left = seconds
        while left > 0 {
            step(min(left, 1.0 / 30), into: buffer)
            left -= 1.0 / 30
        }
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: Encoding

    private func uniforms(dt: Double) -> FlowUniforms {
        let palette = shownPalette()
        let t = simulation.time
        func drop(_ d: Int) -> SIMD4<Float> { simulation.color(of: d, in: palette).oklab }
        let angle = 0.9 + 0.8 * sin(t * 0.031 + Double(seed)) // the gradient's direction swings around
        return FlowUniforms(
            background: palette.background.oklab,
            liquid: palette.liquid.oklab,
            halo: palette.halo.oklab,
            drops: (drop(0), drop(1), drop(2), drop(3)),
            flowDrift: SIMD2(Float(4 * cos(t * 0.021)), Float(4 * sin(t * 0.017))),
            colorDrift: SIMD2(Float(3 * cos(t * 0.013)), Float(3 * sin(t * 0.011))),
            gradient: SIMD2(Float(cos(angle)), Float(sin(angle))),
            aspect: Float(simulation.aspect),
            dt: Float(dt),
            rise: 2.2,
            fall: 0.5,
            swirl: 0.035,
            drag: 0.55,
            grain: grain,
            grainSeed: grainSeed,
            lobeCount: Int32(simulation.settings.dropCount * FlowSimulation.lobesPerDrop),
            hueSwing: Float(0.07 * sin(t * 0.09 + Double(seed))),
            seed: seed
        )
    }

    /// The dye textures for the current aspect ratio, (re)created empty when it changes.
    private func dyeTextures() -> [MTLTexture] {
        let width = max(Int((Double(Self.dyeHeight) * simulation.aspect).rounded()), 1)
        if let first = dye.first, first.width == width { return dye }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: Self.dyeHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        dye = (0 ..< 2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        // Start empty.
        if let buffer = queue.makeCommandBuffer() {
            for texture in dye {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
                buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            buffer.commit()
        }
        return dye
    }

    /// Moves the drops by `dt` and updates the dye accordingly.
    private func step(_ dt: Double, into buffer: MTLCommandBuffer) {
        let simulated = simulation.step(dt)
        grainSeed = (grainSeed &+ 1) & 0xFFFFF
        let textures = dyeTextures()
        guard textures.count == 2 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = textures[1]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms(dt: simulated)
        var lobes = simulation.renderLobes()
        encoder.setRenderPipelineState(dyePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&lobes, length: MemoryLayout<FlowLobeUniform>.stride * lobes.count, index: 1)
        encoder.setFragmentTexture(textures[0], index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        dye.swapAt(0, 1)
    }

    private func compose(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor) {
        guard let dye = dyeTextures().first,
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms(dt: 0)
        encoder.setRenderPipelineState(flowPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.setFragmentTexture(dye, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Offscreen

    /// A still picture of a Flow (desktop pictures, thumbnails): the same `seed` gives the same
    /// picture. `time` is how long the drops move before the picture is taken.
    public static func still(palette: FlowPalette, settings: FlowSettings, width: Int, height: Int,
                             seed: UInt64 = 3, time: Double = 12, grain: Float = 0) -> CGImage? {
        let aspect = Double(width) / Double(max(height, 1))
        guard let renderer = FlowRenderer(palette: palette, settings: settings, aspect: aspect, seed: seed) else { return nil }
        renderer.grain = grain
        renderer.advance(by: time, aspect: aspect)
        return renderer.image(width: width, height: height)
    }

    /// Renders the current state to an image (desktop pictures, thumbnails). The aspect ratio
    /// follows `width`/`height`; changing it starts the dye over, so call `advance` after.
    public func image(width: Int, height: Int) -> CGImage? {
        simulation.aspect = Double(width) / Double(max(height, 1))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        compose(into: buffer, pass: pass)
        buffer.commit()
        buffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

extension FlowRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        simulation.aspect = Double(size.width / max(size.height, 1))
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        guard let buffer = queue.makeCommandBuffer() else { return }
        simulation.aspect = Double(view.drawableSize.width / max(view.drawableSize.height, 1))
        if isAnimating, let last = lastTimestamp {
            step(now - last, into: buffer)
        }
        lastTimestamp = now
        if let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            compose(into: buffer, pass: pass)
            buffer.present(drawable)
        }
        buffer.commit()
    }
}
