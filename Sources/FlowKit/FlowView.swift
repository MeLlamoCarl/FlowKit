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

    public init(palette: FlowPalette, settings: FlowSettings, isAnimating: Bool = true,
                framesPerSecond: Int = 30, grain: Float = 0.012, paletteTransition: Double = 1.5) {
        self.paletteTransition = paletteTransition
        self.palette = palette
        self.settings = settings
        self.isAnimating = isAnimating
        self.framesPerSecond = framesPerSecond
        self.grain = grain
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
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
        renderer.isAnimating = isAnimating
        view.preferredFramesPerSecond = framesPerSecond
        view.enableSetNeedsDisplay = !isAnimating
        view.isPaused = !isAnimating
        if !isAnimating { view.needsDisplay = true }
    }

    public final class Coordinator {
        var renderer: FlowRenderer?
    }
}
