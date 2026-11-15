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
/// Each frame: the liquid's particles are splatted into a density texture, the halo ink is
/// updated from it, and the picture is composed. Both textures have a fixed height, independent
/// of the output size: density and ink are smooth, so low-resolution buffers scaled up look the
/// same and cost little.
public final class FlowRenderer: NSObject {
    public let device: MTLDevice
    private let splatPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
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
    private var trail: [MTLTexture] = []
    private var density: MTLTexture?
    /// The same particles splatted much larger: the liquid's broad, smooth shape, for its wide
    /// color gradient and its own glow.
    private var broad: MTLTexture?
    private var lastTimestamp: CFTimeInterval?
    private let seed: Float
    /// Grain strength (0 disables it).
    public var grain: Float = 0.01
    /// Advance the simulation on each draw; off for a still picture.
    public var isAnimating = true

    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private static let trailHeight = 360
    private static let densityHeight = 540
    private static let broadHeight = 180
    /// Broad splats, relative to the regular ones.
    private static let broadScale = 3.5
    /// Each particle's splat radius, relative to the particle spacing.
    private static let splatScale = 2.8

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
            let splat = MTLRenderPipelineDescriptor()
            splat.vertexFunction = library.makeFunction(name: "splatVertex")
            splat.fragmentFunction = library.makeFunction(name: "splatFragment")
            let attachment = splat.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Float
            attachment.isBlendingEnabled = true // splats add up
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
            splatPipeline = try device.makeRenderPipelineState(descriptor: splat)
            trailPipeline = try pipeline("trailFragment", .rg16Float)
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
        self.seed = Float(seed % 1000) / 10
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

    /// Runs the motion and the trail forward by `seconds` at once (in small steps), e.g. to start
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

    private func uniforms(size: CGSize, dt: Double) -> FlowUniforms {
        let palette = shownPalette()
        return FlowUniforms(
            background: palette.background.simd,
            backgroundLight: palette.background.shifted(lightness: 0.04).simd,
            backgroundDark: palette.background.shifted(lightness: -0.07).simd,
            halo: palette.halo.simd,
            liquid: palette.liquid.simd,
            resolution: SIMD2(Float(size.width), Float(size.height)),
            time: Float(simulation.time),
            aspect: Float(simulation.aspect),
            dt: Float(dt),
            iso: Float(Self.isoLevel),
            decay: 0.42,
            inject: 1,
            swirl: 0.04,
            drag: 0.3,
            grain: grain,
            dropCount: Int32(simulation.dropRadii.count),
            seed: seed,
            accumulate: 3.5,
            splatRadius: Float(FlowSimulation.spacing * Self.splatScale)
        )
    }

    /// Density at the liquid's surface: a fraction of an interior point's (particles per area ×
    /// the splat kernel's integral, π R² / 3).
    private static var isoLevel: Double {
        let s = FlowSimulation.spacing
        let perArea = 2 / (sqrt(3) * s * s)
        let radius = s * splatScale
        return 0.45 * perArea * .pi * radius * radius / 3
    }

    private func dropData() -> [FlowDropUniform] {
        let drops = simulation.renderDrops(palette: shownPalette())
        return drops.isEmpty ? [FlowDropUniform(color: .zero, center: .zero, velocity: .zero, radius: 0)] : drops
    }

    /// The density texture for the current aspect ratio.
    private func densityTexture() -> MTLTexture? {
        density = texture(density, height: Self.densityHeight)
        return density
    }

    private func broadTexture() -> MTLTexture? {
        broad = texture(broad, height: Self.broadHeight)
        return broad
    }

    private func texture(_ existing: MTLTexture?, height: Int) -> MTLTexture? {
        let width = max(Int((Double(height) * simulation.aspect).rounded()), 1)
        if let existing, existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Splats the drops into the density texture and, larger, into the broad one.
    private func renderDensity(into buffer: MTLCommandBuffer) {
        let drops = simulation.renderParticles()
        let dropRadius = Float(FlowSimulation.spacing * Self.splatScale)
        splat(drops, into: densityTexture(), radius: dropRadius, weight: 1, buffer: buffer)
        splat(drops, into: broadTexture(), radius: dropRadius * Float(Self.broadScale),
              weight: Float(1 / (Self.broadScale * Self.broadScale)), buffer: buffer)
    }

    private func splat(_ particles: [SIMD4<Float>], into texture: MTLTexture?, radius: Float, weight: Float,
                       buffer: MTLCommandBuffer) {
        guard let texture else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !particles.isEmpty,
           let particleBuffer = device.makeBuffer(bytes: particles, length: MemoryLayout<SIMD4<Float>>.stride * particles.count) {
            var uniforms = uniforms(size: CGSize(width: texture.width, height: texture.height), dt: 0)
            uniforms.splatRadius = radius
            uniforms.splatWeight = weight
            encoder.setRenderPipelineState(splatPipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
        }
        encoder.endEncoding()
    }

    /// The trail textures for the current aspect ratio, (re)created empty when it changes.
    private func trailTextures() -> [MTLTexture] {
        let width = max(Int((Double(Self.trailHeight) * simulation.aspect).rounded()), 1)
        if let first = trail.first, first.width == width, first.height == Self.trailHeight { return trail }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: width, height: Self.trailHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        trail = (0 ..< 2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        // Start empty.
        if let buffer = queue.makeCommandBuffer() {
            for texture in trail {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            buffer.commit()
        }
        return trail
    }

    /// Moves the drops by `dt` and updates the trail accordingly.
    private func step(_ dt: Double, into buffer: MTLCommandBuffer) {
        simulation.step(dt)
        renderDensity(into: buffer)
        let textures = trailTextures()
        guard textures.count == 2, let density = densityTexture() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = textures[1]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms(size: CGSize(width: textures[1].width, height: textures[1].height),
                                dt: min(max(dt, 0), 1.0 / 15))
        var drops = dropData()
        encoder.setRenderPipelineState(trailPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&drops, length: MemoryLayout<FlowDropUniform>.stride * drops.count, index: 1)
        encoder.setFragmentTexture(textures[0], index: 0)
        encoder.setFragmentTexture(density, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        trail.swapAt(0, 1)
    }

    private func compose(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        let textures = trailTextures()
        if density == nil || density?.width != max(Int((Double(Self.densityHeight) * simulation.aspect).rounded()), 1) {
            renderDensity(into: buffer)
        }
        guard let ink = textures.first, let density = densityTexture(), let broad = broadTexture(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms(size: size, dt: 0)
        var drops = dropData()
        encoder.setRenderPipelineState(flowPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&drops, length: MemoryLayout<FlowDropUniform>.stride * drops.count, index: 1)
        encoder.setFragmentTexture(ink, index: 0)
        encoder.setFragmentTexture(density, index: 1)
        encoder.setFragmentTexture(broad, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Offscreen

    /// A still picture of a Flow (desktop pictures, thumbnails): the same `seed` gives the same
    /// picture. `time` is how long the liquid moves before the picture is taken.
    public static func still(palette: FlowPalette, settings: FlowSettings, width: Int, height: Int,
                             seed: UInt64 = 7, time: Double = 6, grain: Float = 0) -> CGImage? {
        let aspect = Double(width) / Double(max(height, 1))
        guard let renderer = FlowRenderer(palette: palette, settings: settings, aspect: aspect, seed: seed) else { return nil }
        renderer.grain = grain
        renderer.advance(by: time, aspect: aspect)
        return renderer.image(width: width, height: height)
    }

    /// Renders the current state to an image (desktop pictures, thumbnails). The aspect ratio
    /// follows `width`/`height`; changing it starts the trail over, so call `advance` after.
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
        compose(into: buffer, pass: pass, size: CGSize(width: width, height: height))
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
            compose(into: buffer, pass: pass, size: view.drawableSize)
            buffer.present(drawable)
        }
        buffer.commit()
    }
}
