//
//  FlowShaders.swift
//  FlowKit
//

import simd

/// Mirrors `Drop` in the shaders (48 bytes). Drop `i` is channel `i` of the density texture.
struct FlowDropUniform {
    var color: SIMD4<Float>
    var center: SIMD2<Float>
    var velocity: SIMD2<Float>
    /// Rest radius.
    var radius: Float
}

/// Mirrors `Uniforms` in the shaders (144 bytes).
struct FlowUniforms {
    var background: SIMD4<Float>
    var backgroundLight: SIMD4<Float>
    var backgroundDark: SIMD4<Float>
    var halo: SIMD4<Float>
    var liquid: SIMD4<Float>
    var resolution: SIMD2<Float>
    var time: Float
    var aspect: Float
    /// Seconds since the previous trail update.
    var dt: Float
    /// Density at the liquid's surface.
    var iso: Float
    /// Fraction of the halo ink left after one second.
    var decay: Float
    /// Ink filling the liquid's body.
    var inject: Float
    /// Strength of the swirling flow that turns the trail into wisps.
    var swirl: Float
    /// How much moving liquid drags the ink around it along.
    var drag: Float
    var grain: Float
    var dropCount: Int32
    var seed: Float
    /// Ink added per second along the surface; it piles up around slow liquid as a glowing rim.
    var accumulate: Float
    /// Radius of each particle's splat, in screen heights.
    var splatRadius: Float
    /// Weight of each splat (1 / scale² for larger splats, so every density has the same scale).
    var splatWeight: Float = 1
}

/// Compiled at runtime (`makeLibrary(source:)`), so the package needs no Metal build step.
///
/// Three passes:
/// - `splatVertex`/`splatFragment` add up the particles as soft round splats into a density
///   texture, one color channel per drop (metaballs): the liquid's surface is where the density
///   crosses `iso`.
/// - `trailFragment` updates the halo ink (single channel, ping-ponged each frame):
///   semi-Lagrangian advection through a curl-noise flow plus the liquid's wake (as in Jos Stam's
///   "Stable Fluids"), a little diffusion, fading, and fresh ink from the liquid itself, so moving
///   liquid leaves a glowing, smoky trail.
/// - `flowFragment` composes background, ink in the halo color and the liquid: its color turns
///   from the glow at the surface to the drop color in its depth, so it all reads as one
///   luminous liquid.
let flowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Drop {
    float4 color;
    float2 center;
    float2 velocity;
    float radius;
};

struct Uniforms {
    float4 background;
    float4 backgroundLight;
    float4 backgroundDark;
    float4 halo;
    float4 liquid;
    float2 resolution;
    float time;
    float aspect;
    float dt;
    float iso;
    float decay;
    float inject;
    float swirl;
    float drag;
    float grain;
    int dropCount;
    float seed;
    float accumulate;
    float splatRadius;
    float splatWeight;
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

// MARK: Density

struct SplatOut {
    float4 position [[position]];
    float2 local;
    float4 channel;
    float weight;
};

vertex SplatOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant float4 *particles [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                                float2(1, -1), float2(1, 1), float2(-1, 1) };
    float4 particle = particles[iid];
    float2 corner = corners[vid];
    float2 world = particle.xy + corner * u.splatRadius;
    SplatOut out;
    out.position = float4(world.x / u.aspect * 2.0 - 1.0, 1.0 - world.y * 2.0, 0.0, 1.0);
    out.local = corner;
    out.weight = u.splatWeight;
    int drop = int(particle.z + 0.5);
    out.channel = float4(drop == 0, drop == 1, drop == 2, drop == 3);
    return out;
}

fragment float4 splatFragment(SplatOut in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    float w = max(1.0 - r2, 0.0);
    return in.channel * (w * w * in.weight);
}

// MARK: Helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(13.1, 7.7);
        a *= 0.5;
    }
    return v;
}

static float flowNoise(float2 p, float t) {
    return vnoise(p + float2(t, -t * 0.7)) + 0.5 * vnoise(p * 2.1 + float2(-t * 1.3, t) + 9.2);
}

// Curl of a noise field: swirling, divergence-free velocity (ink curls instead of clumping).
static float2 curlNoise(float2 p, float t) {
    const float e = 0.03;
    float a = flowNoise(p + float2(0, e), t), b = flowNoise(p - float2(0, e), t);
    float c = flowNoise(p + float2(e, 0), t), d = flowNoise(p - float2(e, 0), t);
    return float2(a - b, -(c - d)) / (2.0 * e);
}

// Total liquid density relative to the surface level (1 = surface, more = deeper inside).
static float liquidLevel(float4 density, constant Uniforms &u) {
    return (density.r + density.g + density.b + density.a) / u.iso;
}

// MARK: Trail

fragment float4 trailFragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant Drop *drops [[buffer(1)]],
                              texture2d<float> previous [[texture(0)]],
                              texture2d<float> density [[texture(1)]],
                              sampler smp [[sampler(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);

    // Two flows. The halo ink: a slow swirl plus each drop dragging it along in its wake. The
    // background liquid: the same swirl plus each drop pushing it aside, the potential flow around
    // a moving disc outside it (fluid parts in front and closes in behind: R²/r² (2(U·r̂)r̂ − U))
    // and the drop's own velocity inside.
    float2 swirl = curlNoise(p * 2.4 + u.seed, u.time * 0.12) * u.swirl;
    float2 inkVelocity = swirl, liquidVelocity = swirl;
    for (int i = 0; i < u.dropCount; i++) {
        constant Drop &d = drops[i];
        float2 rel = p - d.center;
        float r = max(length(rel), 1e-4);
        float2 dir = rel / r;
        float R = d.radius;
        inkVelocity += d.velocity * exp(-max(r - R, 0.0) / (R * 0.45)) * u.drag;
        float2 around = (R * R) / (r * r) * (2.0 * dot(d.velocity, dir) * dir - d.velocity);
        liquidVelocity += mix(d.velocity, around, smoothstep(R * 0.85, R * 1.1, r));
    }

    // Advect: fetch each from where this point's fluid came from.
    float2 texel = 1.0 / float2(previous.get_width(), previous.get_height());
    float2 inkBack = p - inkVelocity * u.dt;
    float2 uv = float2(inkBack.x / u.aspect, inkBack.y);
    float ink = previous.sample(smp, uv).r;
    float spread = 0.25 * (previous.sample(smp, uv + float2(texel.x, 0)).r +
                           previous.sample(smp, uv - float2(texel.x, 0)).r +
                           previous.sample(smp, uv + float2(0, texel.y)).r +
                           previous.sample(smp, uv - float2(0, texel.y)).r);
    ink = mix(ink, spread, 0.6);
    ink *= pow(u.decay, u.dt);

    // The background liquid's thickness (lighter or darker patches of its color): stirred by the
    // drops, slowly settling back to a calm pattern.
    float2 liquidBack = p - liquidVelocity * u.dt;
    float thickness = previous.sample(smp, float2(liquidBack.x / u.aspect, liquidBack.y)).g;
    float calm = fbm(p * 1.3 + float2(u.time * 0.012, -u.time * 0.009) + u.seed * 1.7);
    thickness = mix(thickness, calm, 1.0 - pow(0.88, u.dt));

    // Fresh ink: the liquid's body is full of it (hidden under the liquid, it shows once the
    // liquid moves on), and more keeps piling up at its surface (a glowing rim around slow liquid).
    float level = liquidLevel(density.sample(smp, in.uv), u);
    ink = max(ink, smoothstep(0.8, 1.2, level) * u.inject);
    ink += exp(-abs(level - 1.0) * 2.5) * smoothstep(0.15, 0.5, level) * u.accumulate * u.dt;
    ink = min(ink, 2.0);
    return float4(ink, thickness, 0.0, 1.0);
}

// MARK: Compose

fragment float4 flowFragment(VOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             constant Drop *drops [[buffer(1)]],
                             texture2d<float> trail [[texture(0)]],
                             texture2d<float> densityTexture [[texture(1)]],
                             texture2d<float> broadTexture [[texture(2)]],
                             sampler smp [[sampler(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);
    float t = u.time;

    // Background: nearly flat, lighter in the middle, with faint slow patches.
    float n = fbm(p * 1.1 + float2(u.seed, -u.seed) + float2(t * 0.015, -t * 0.011));
    float vignette = smoothstep(0.15, 0.85, length(in.uv - 0.5) * 1.25 + (n - 0.5) * 0.3);
    float3 bg = mix(u.backgroundLight.rgb, u.backgroundDark.rgb, vignette);
    bg = mix(u.background.rgb, bg, 0.85);

    // The background liquid covering the screen: its color over the background, thicker or
    // thinner where the drops stir it.
    float thickness = smoothstep(0.2, 0.8, trail.sample(smp, in.uv).g);
    float3 liquid = u.liquid.rgb + (bg - u.background.rgb);
    bg = mix(bg, liquid, 0.15 + 0.85 * thickness);

    // One luminous liquid, no edges: the drop color only at the heart of the liquid, the glow
    // everywhere around it (from the liquid itself and from the ink it leaves behind), fading
    // into the background.
    float ink = trail.sample(smp, in.uv).r;
    float4 density = densityTexture.sample(smp, in.uv);
    float total = density.r + density.g + density.b + density.a;
    float level = total / u.iso; // 1 ≈ the liquid's outer layer, ~2.2 its heart
    // The broad density (the same particles splatted 3.5× larger, so the same 1/iso scale, ~2.2
    // in the heart): the liquid's smooth large-scale shape, for wide, soft gradients.
    float4 broad = broadTexture.sample(smp, in.uv);
    float broadLevel = (broad.r + broad.g + broad.b + broad.a) / u.iso;
    float glow = max((1.0 - exp(-ink * 2.2)) * 0.85, smoothstep(0.05, 1.0, broadLevel));
    glow = max(glow, smoothstep(0.2, 1.0, level));
    float3 c = mix(bg, u.halo.rgb, glow);

    if (u.dropCount > 0 && broadLevel > 0.5) {
        float4 weights = density / max(total, 1e-5);
        float3 color = float3(0.0);
        float2 center = float2(0.0), velocity = float2(0.0);
        float radius = 0.0;
        for (int i = 0; i < u.dropCount; i++) {
            color += weights[i] * drops[i].color.rgb;
            center += weights[i] * drops[i].center;
            velocity += weights[i] * drops[i].velocity;
            radius += weights[i] * drops[i].radius;
        }
        // The heart's color retreats inward, and swirls, on the side the liquid leaves behind.
        float2 toPoint = p - center;
        float len = max(length(toPoint), 1e-5);
        float speed = length(velocity);
        float trailing = speed > 1e-5 ? max(dot(toPoint / len, -velocity / speed), 0.0) : 0.0;
        trailing *= smoothstep(0.0, radius * 0.5, len);
        float motion = clamp(speed * 4.0, 0.0, 1.0);
        float swirl = fbm(p * 3.2 + float2(t * 0.22, -t * 0.17) + u.seed);
        float shift = 0.35 * trailing * motion + 0.2 * (swirl - 0.5);
        float heart = smoothstep(1.0 + shift, 2.0 + shift * 0.5, broadLevel) * smoothstep(0.6, 1.4, level);
        c = mix(c, color, heart);
    }

    // Fine grain hides banding in the smooth gradients.
    float g = hash21(in.uv * u.resolution + fract(t * 7.0) * 100.0) - 0.5;
    c += g * u.grain;
    return float4(c, 1.0);
}
"""
