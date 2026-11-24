//
//  FlowShaders.swift
//  FlowKit
//

import simd

/// Mirrors `Lobe` in the shaders (32 bytes).
struct FlowLobeUniform {
    var center: SIMD2<Float>
    /// Screen heights per second of simulated time.
    var velocity: SIMD2<Float>
    var radius: Float
    var amplitude: Float
    /// The drop it belongs to: its channel in the dye texture.
    var drop: Int32
}

/// Mirrors `Uniforms` in the shaders (192 bytes). Colors are OKLab.
struct FlowUniforms {
    var background: SIMD4<Float>
    var liquid: SIMD4<Float>
    var halo: SIMD4<Float>
    var drops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    /// Offsets of the noise fields, gliding along closed curves (bounded, so the noise keeps its
    /// precision however long it runs).
    var flowDrift: SIMD2<Float>
    var colorDrift: SIMD2<Float>
    /// Direction of the background's gradient.
    var gradient: SIMD2<Float>
    var aspect: Float
    /// Simulated seconds since the previous dye update.
    var dt: Float
    /// How fast dye builds up and fades away, per second.
    var rise: Float
    var fall: Float
    /// Strength of the slow, large-scale stirring.
    var swirl: Float
    /// How much moving drops carry the dye around them along.
    var drag: Float
    var grain: Float
    var grainSeed: UInt32
    var lobeCount: Int32
    /// Slow swing of the hues, radians.
    var hueSwing: Float
    var seed: Float
}

/// Compiled at runtime (`makeLibrary(source:)`), so the package needs no Metal build step.
///
/// Two passes:
/// - `dyeFragment` updates the dye (one channel per drop, ping-ponged each frame): carried along by
///   a slow stirring flow and by the drops' motion, spreading a little, and heading for the shape
///   of the drops (soft blobs that merge), quickly where it builds up and slowly where it fades.
///   So fronts are crisp and what drops leave behind is wide and soft.
/// - `flowFragment` colors it: the more dye, the further from the background through the halo
///   color to the drop color.
///
/// The noise hashes integers: floating-point hashes round differently depending on how each GPU's
/// compiler arranges them, and lattice points that disagree between cells show up as straight cuts.
let flowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Lobe {
    float2 center;
    float2 velocity;
    float radius;
    float amplitude;
    int drop;
};

struct Uniforms {
    float4 background;
    float4 liquid;
    float4 halo;
    float4 drops[4];
    float2 flowDrift;
    float2 colorDrift;
    float2 gradient;
    float aspect;
    float dt;
    float rise;
    float fall;
    float swirl;
    float drag;
    float grain;
    uint grainSeed;
    int lobeCount;
    float hueSwing;
    float seed;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut flowVertex(uint vid [[vertex_id]]) {
    // One triangle covering the target.
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: Noise

static uint hashBits(int2 p) {
    uint h = uint(p.x) * 0x9E3779B1u ^ uint(p.y) * 0x85EBCA77u;
    h = (h ^ (h >> 15)) * 0x2C1B3C6Du;
    h = (h ^ (h >> 12)) * 0x297A2D39u;
    return h ^ (h >> 15);
}

static float hash21(int2 p) {
    return float(hashBits(p) >> 8) / 16777216.0;
}

// Value noise with smooth first and second derivatives (its slopes drive the flow).
static float vnoise(float2 p) {
    float2 cell = floor(p), f = p - cell;
    int2 i = int2(cell);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i), b = hash21(i + int2(1, 0));
    float c = hash21(i + int2(0, 1)), d = hash21(i + int2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float flowNoise(float2 p, float2 drift) {
    return vnoise(p + drift) + 0.4 * vnoise(p * 1.9 - drift.yx * 1.3 + 9.2);
}

// Curl of a noise field: swirling, divergence-free velocity (dye curls instead of clumping).
static float2 curlNoise(float2 p, float2 drift) {
    const float e = 0.05;
    float a = flowNoise(p + float2(0, e), drift), b = flowNoise(p - float2(0, e), drift);
    float c = flowNoise(p + float2(e, 0), drift), d = flowNoise(p - float2(e, 0), drift);
    return float2(a - b, -(c - d)) / (2.0 * e);
}

// MARK: Dye

fragment float4 dyeFragment(VOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            constant Lobe *lobes [[buffer(1)]],
                            texture2d<float> previous [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);

    // The drops' outline wavers, so none is a perfect disc.
    float2 warp = float2(vnoise(p * 1.35 + u.flowDrift * 1.4 + u.seed),
                         vnoise(p * 1.35 - u.flowDrift.yx * 1.4 + u.seed + 41.0)) - 0.5;
    float2 warped = p + warp * 0.26;

    float2 velocity = curlNoise(p * 1.4 + u.seed, u.flowDrift) * u.swirl;
    float4 shape = float4(0.0);
    for (int i = 0; i < u.lobeCount; i++) {
        constant Lobe &lobe = lobes[i];
        float2 rel = warped - lobe.center;
        float amount = lobe.amplitude * exp(-dot(rel, rel) / (lobe.radius * lobe.radius));
        shape[lobe.drop] += amount;
        velocity += lobe.velocity * min(amount, 1.0) * u.drag;
    }
    float4 target = smoothstep(0.02, 1.05, shape);

    // Carry the dye along: fetch it from where this point's fluid came from.
    float2 back = p - velocity * u.dt;
    float2 uv = float2(back.x / u.aspect, back.y);
    float2 texel = 1.0 / float2(previous.get_width(), previous.get_height());
    float4 dye = previous.sample(smp, uv);
    float4 spread = 0.25 * (previous.sample(smp, uv + float2(texel.x, 0)) +
                            previous.sample(smp, uv - float2(texel.x, 0)) +
                            previous.sample(smp, uv + float2(0, texel.y)) +
                            previous.sample(smp, uv - float2(0, texel.y)));
    dye = mix(dye, spread, 1.0 - exp(-u.dt * 30.0));

    float4 rate = mix(float4(u.fall), float4(u.rise), smoothstep(-0.05, 0.05, target - dye));
    return mix(dye, target, 1.0 - exp(-rate * u.dt));
}

// MARK: Compose

// B-spline bicubic sampling (4 bilinear fetches): the dye texture is small, and its contours
// would show its texels with bilinear scaling.
static float4 sampleSmooth(texture2d<float> tex, sampler smp, float2 uv) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 st = uv * size - 0.5;
    float2 i = floor(st), f = st - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 w2 = 1.0 - w0 - w1 - w3;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 a = (i - 0.5 + w1 / g0) / size, b = (i + 1.5 + w3 / g1) / size;
    return (tex.sample(smp, a) * g0.x + tex.sample(smp, float2(b.x, a.y)) * g1.x) * g0.y +
           (tex.sample(smp, float2(a.x, b.y)) * g0.x + tex.sample(smp, b) * g1.x) * g1.y;
}

static float3 rotateHue(float3 lab, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(lab.x, lab.y * c - lab.z * s, lab.y * s + lab.z * c);
}

static float3 oklabToSRGB(float3 lab) {
    float3 lms = float3(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
                        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
                        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    float3 rgb = float3(4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076127010 * lms.z);
    rgb = clamp(rgb, 0.0, 1.0);
    return select(1.055 * pow(max(rgb, 1e-6), 1.0 / 2.4) - 0.055, 12.92 * rgb, rgb <= 0.0031308);
}

fragment float4 flowFragment(VOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> dyeTexture [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);

    // Background: its two colors across the screen, along a gradient that turns and wavers.
    float2 centered = float2(in.uv.x - 0.5, in.uv.y - 0.5);
    float n = vnoise(p * 1.2 + u.colorDrift + u.seed * 1.7) - 0.5;
    float along = dot(centered, u.gradient) + n * 0.7;
    float3 color = mix(u.background.rgb, u.liquid.rgb, smoothstep(-0.55, 0.55, along));

    float4 dye = max(sampleSmooth(dyeTexture, smp, in.uv), 0.0);
    float total = dye.r + dye.g + dye.b + dye.a;
    float swing = u.hueSwing + (vnoise(p * 1.1 - u.colorDrift + u.seed) - 0.5) * 0.14;

    float halo = smoothstep(0.02, 0.40, total);
    color = mix(color, rotateHue(u.halo.rgb, swing * 0.6), halo);

    float core = smoothstep(0.44, 0.76, total);
    float3 drop = (dye.r * u.drops[0].rgb + dye.g * u.drops[1].rgb +
                   dye.b * u.drops[2].rgb + dye.a * u.drops[3].rgb) / max(total, 1e-4);
    color = mix(color, rotateHue(drop, swing), core);

    // Fine grain hides banding in the smooth gradients.
    float3 rgb = oklabToSRGB(color);
    float g = hash21(int2(in.position.xy) + int2(int(u.grainSeed & 1023u) * 7, int(u.grainSeed >> 10) * 13)) - 0.5;
    return float4(rgb + g * u.grain, 1.0);
}
"""
