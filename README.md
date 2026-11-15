# FlowKit

Live "Flow" wallpapers for macOS: glowing drops of liquid drifting through a liquid background,
rendered with Metal. Used by [Meshy](https://github.com/MeLlamoCarl/Meshy).

## How it works

- **Drops** are bodies of thick, cohesive liquid simulated with particles (Clavet, Beaudoin and
  Poulin, *Particle-based Viscoelastic Fluid Simulation*, 2005: double density relaxation plus
  viscosity), with extra surface tension that keeps each drop round in the open and lets it
  flatten against the screen's edges. Each drop drifts toward a point gliding along a slow
  Lissajous curve.
- The **background liquid** and the drops' glowing **halo** are fields advected on the GPU
  (semi-Lagrangian, Stam's *Stable Fluids*): the halo trails behind the drops like smoke, and
  the background liquid parts around them and settles back.
- Drops are drawn as metaballs from their particles. Colors are mixed in OKLab.

## Usage

```swift
import FlowKit

let palette = FlowPreset.all[0].palette
let view = FlowView(palette: palette, settings: .default)       // SwiftUI

let renderer = FlowRenderer(palette: palette, settings: .default) // or drive an MTKView yourself
let image = renderer?.image(width: 1920, height: 1080)           // a still frame
```

`FlowPalette` holds the background, background liquid, drop and halo colors; `FlowSettings`
the number of drops (1–4), their size range and speed.

Requires macOS 13. Licensed under the MIT License (see `LICENSE.txt`).
