#include <metal_stdlib>
using namespace metal;

// Stars pass. Draws the Yale Bright Star Catalog (BSC5) as additive point
// sprites at the END of the composition, at native resolution (on the MetalFX
// path the rest of the frame is upscaled from half res; 2-7 px points must not
// be). Cloud occlusion happens here: the fragment multiplies by the cloud
// transmittance (1 - alpha) sampled from the cloud target — mathematically
// identical to drawing the stars before the premultiplied "over" blend
// (additive terms commute with it).
//
// Unlike the sun and moon, stars do NOT light anything: no halo, no atmosphere
// contribution — passive dots. Each star carries a world-space direction
// (Aether convention: -Z = North, +X = East, +Y = up) resolved on the CPU for
// the scene's location/time; the vertex shader projects it to clip space by
// inverting the sky ray reconstruction in Background.metal, so stars stay
// world-locked under gaze rotation/zoom and agree pixel-for-pixel with the sky.
//
// Reference: Yale Bright Star Catalog, 5th rev. ed. (Hoffleit & Warren 1991),
// via the ADC / Harvard. See BIBLIO.md.

// One catalog star. Layout must match `GPUStar` in `Renderer` (two float4).
struct GPUStar {
    float4 dirMag;  // xyz: world direction; w: visual magnitude
    float4 extra;   // x: B-V colour index; yzw: unused
};

// Per-frame star uniforms. Layout must match `StarUniforms` in `Renderer`.
struct StarUniforms {
    float4 camRight;    // xyz: camera→world basis (same as SkyUniforms)
    float4 camUp;
    float4 camForward;
    float4 params;      // x: tan(vertical FOV/2); y: aspect; z: night weight; w: time (s)
};

struct StarInOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float3 color [[flat]];  // tint × brightness × gates, premultiplied
    float2 uv [[flat]];     // screen UV of the star centre (cloud occlusion)
};

// --- Tunable constants ------------------------------------------------------

// Faint cutoff: magnitude mapped to ~0 brightness. BSC5 reaches ~6.5.
constant float kMagnitudeCutoff = 6.5;
// Linear gain after perceptual (sqrt) flux compression. Sets overall density:
// mag 6.5 → ~0.14 (just visible), mag 4 → ~0.35, mag ≤1 → saturates to white.
constant float kBrightnessGain = 0.14;
// Point-sprite size range (full-res drawable pixels) and brightness→size weight.
constant float kSizeMin = 2.0;
constant float kSizeMax = 7.0;
// Reference half-FOV tangent (~53° vertical) for zoom-coherent sizing.
constant float kReferenceTanHalfFov = 0.5;
// Subtle twinkle (contemplative): small amplitude, slow.
constant float kTwinkleAmplitude = 0.12;
constant float kTwinkleSpeed = 2.3;

// B-V colour index → approximate stellar RGB tint (blue → white → orange).
static float3 starTint(float bv) {
    const float t = clamp(bv, -0.4, 2.0);
    const float3 cool = float3(0.62, 0.72, 1.0);  // hot blue stars
    const float3 mid  = float3(1.0, 1.0, 1.0);     // white (B-V ~ 0.6)
    const float3 warm = float3(1.0, 0.78, 0.55);   // cool orange/red stars
    if (t < 0.6) {
        return mix(cool, mid, (t + 0.4) / 1.0);
    }
    return mix(mid, warm, (t - 0.6) / 1.4);
}

vertex StarInOut star_vertex(uint vid [[vertex_id]],
                             const device GPUStar *stars [[buffer(0)]],
                             constant StarUniforms &u [[buffer(1)]]) {
    StarInOut out;
    const GPUStar star = stars[vid];
    const float3 dir = star.dirMag.xyz;

    const float tanHalfFov = u.params.x;
    const float aspect = u.params.y;
    const float nightWeight = u.params.z;
    const float time = u.params.w;

    // Project the world direction into clip space — inverse of the sky ray
    // (Background.metal): rayDir = ndcX·tanHalfFov·aspect·right + ndcY·tanHalfFov·up + forward.
    const float zc = dot(dir, u.camForward.xyz);
    if (zc <= 1e-4) {
        // Behind the camera: reject via the clipper (z/w > 1), not point_size 0.
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.pointSize = 0.0;
        out.color = float3(0.0);
        out.uv = float2(0.0);
        return out;
    }
    const float xc = dot(dir, u.camRight.xyz);
    const float yc = dot(dir, u.camUp.xyz);
    const float ndcX = xc / (zc * tanHalfFov * aspect);
    const float ndcY = yc / (zc * tanHalfFov);
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    // Top-left-origin screen UV (same mapping as Composite.metal), used to
    // sample the cloud transmittance. Constant across the point sprite —
    // negligible over 2-7 px against soft half-res cloud edges.
    out.uv = float2(ndcX * 0.5 + 0.5, 0.5 - ndcY * 0.5);

    // Brightness: Pogson flux, perceptually compressed (raw range ~1600:1).
    const float flux = pow(10.0, -0.4 * (star.dirMag.w - kMagnitudeCutoff));
    float brightness = clamp(sqrt(flux) * kBrightnessGain, 0.0, 1.0);

    // Horizon fade on direction.y (= sin altitude) to avoid popping near the
    // horizon as the time bucket advances.
    const float horizon = smoothstep(-0.0087, 0.0087, dir.y);  // ±0.5°
    // Subtle per-star twinkle (phase from vertex id).
    const float phase = float(vid) * 1.7;
    const float twinkle = 1.0 + kTwinkleAmplitude * sin(time * kTwinkleSpeed + phase);

    brightness *= nightWeight * horizon * twinkle;

    // Zoom-coherent size: stars grow slightly when zoomed in (smaller FOV), to
    // stay consistent with the angular sun/moon discs.
    const float zoom = clamp(kReferenceTanHalfFov / tanHalfFov, 0.7, 2.0);
    out.pointSize = clamp(kSizeMin + brightness * (kSizeMax - kSizeMin), kSizeMin, kSizeMax) * zoom;

    out.color = starTint(star.extra.x) * brightness;
    return out;
}

fragment float4 star_fragment(StarInOut in [[stage_in]],
                              float2 pointCoord [[point_coord]],
                              texture2d<float> cloud [[texture(0)]]) {
    // Soft round dot: radial falloff from the sprite centre.
    const float d = length(pointCoord - 0.5) * 2.0;
    const float falloff = smoothstep(1.0, 0.0, d);
    // Cloud occlusion: stars are drawn after the cloud "over" blend, so the
    // occlusion is applied here via the coverage alpha of the cloud target.
    constexpr sampler cloudSampler(address::clamp_to_edge, filter::linear);
    const float transmittance = 1.0 - cloud.sample(cloudSampler, in.uv).a;
    return float4(in.color * falloff * transmittance, 0.0);  // additive (alpha unused)
}
