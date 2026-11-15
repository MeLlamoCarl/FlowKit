//
//  FlowView.swift
//  FlowKit
//

import MetalKit
import SwiftUI

/// A live Flow. `isAnimating` false shows a still frame and stops the render loop (no GPU use).
public struct FlowView: NSViewRepresentable {
    public var palette: FlowPalette
    public var settings: FlowSettings
    public var isAnimating: Bool
    public var framesPerSecond: Int
    public var grain: Float
    /// Seconds to fade between palettes when `palette` changes.
    public var paletteTransition: Double
    /// Drawable size relative to the view's pixels. Flow is soft gradients, so drawing fewer
    /// pixels and letting the compositor scale them up looks the same at a fraction of the GPU.
    public var renderScale: Double

    public init(palette: FlowPalette, settings: FlowSettings, isAnimating: Bool = true,
                framesPerSecond: Int = 30, grain: Float = 0.012, paletteTransition: Double = 1.5,
                renderScale: Double = 0.5) {
        self.paletteTransition = paletteTransition
        self.renderScale = renderScale
        self.palette = palette
        self.settings = settings
        self.isAnimating = isAnimating
        self.framesPerSecond = framesPerSecond
        self.grain = grain
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = ScaledMTKView()
        view.colorPixelFormat = FlowRenderer.pixelFormat
        view.framebufferOnly = true
        view.layer?.isOpaque = true
        if let renderer = FlowRenderer(palette: palette, settings: settings, aspect: 16 / 9, device: view.device ?? MTLCreateSystemDefaultDevice()) {
            view.device = renderer.device
            renderer.advance(by: 4) // start mid-motion rather than from the initial layout
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        update(view, coordinator: context.coordinator)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: MTKView, coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        if renderer.palette != palette { renderer.setPalette(palette, transition: paletteTransition) }
        if renderer.simulation.settings != settings.validated { renderer.setSettings(settings) }
        renderer.grain = grain
        (view as? ScaledMTKView)?.renderScale = renderScale
        renderer.isAnimating = isAnimating
        view.preferredFramesPerSecond = framesPerSecond
        view.enableSetNeedsDisplay = !isAnimating
        view.isPaused = !isAnimating
        if !isAnimating { view.needsDisplay = true }
    }

    /// An MTKView whose drawable is `renderScale` times its pixel size.
    final class ScaledMTKView: MTKView {
        var renderScale: Double = 1 {
            didSet { if renderScale != oldValue { updateDrawableSize() } }
        }

        override func layout() {
            super.layout()
            updateDrawableSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateDrawableSize()
        }

        private func updateDrawableSize() {
            autoResizeDrawable = false
            let scale = (window?.backingScaleFactor ?? 2) * min(max(renderScale, 0.1), 1)
            let size = CGSize(width: max((bounds.width * scale).rounded(), 1), height: max((bounds.height * scale).rounded(), 1))
            if drawableSize != size { drawableSize = size }
        }
    }

    public final class Coordinator {
        var renderer: FlowRenderer?
    }
}
