# FlowKit

Live "Flow" wallpapers for macOS: glowing drops of color that drift, merge, split and dissolve over
a soft gradient, rendered with Metal. Used by [Meshy](https://github.com/MeLlamoCarl/Meshy).

## How it works

- Each **drop** glides along a slow Lissajous curve and is made of a few soft lobes that circle it,
  drift apart and come back, and swell and shrink.
- The lobes feed a **dye** field on the GPU, carried along by a slow stirring flow (semi-Lagrangian
  advection, Stam's *Stable Fluids*). Dye builds up quickly and fades slowly, so a drop's front is
  crisp and what it leaves behind is wide and soft.
- The dye sets the **color**: from the background's gradient, through the halo, to the drop. Colors
  are mixed in OKLab.

## Usage

```swift
import FlowKit

let palette = FlowPreset.all[0].palette
let view = FlowView(palette: palette, settings: .default)       // SwiftUI

let renderer = FlowRenderer(palette: palette, settings: .default) // or drive an MTKView yourself
let image = renderer?.image(width: 1920, height: 1080)           // a still frame
```

`FlowPalette` holds the two background colors, the drop colors and the halo color; `FlowSettings`
the drops' size range and speed.

Requires macOS 13. Licensed under the MIT License (see `LICENSE.txt`).
