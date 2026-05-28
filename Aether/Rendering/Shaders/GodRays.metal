#include <metal_stdlib>
using namespace metal;

// God rays — screen-space radial light scattering ("sun behind clouds").
//
// Crepuscular shafts as a post-process: each pixel marches toward the sun's
// screen position, accumulating a light source that is bright at the sun and
// masked dark by cloud coverage. Where the sun peeks through a gap the source
// survives the march; where a cloud blocks it the source goes dark — so the
// surviving light fans out into shafts around the cloud. Self-gating: nothing at
// night (the sun colour is zero below the horizon), nothing under full overcast
// (the source is fully masked), gentle when the sky is clear.
//
// Reference: Kenny Mitchell, "Volumetric Light Scattering as a Post-Process",
// GPU Gems 3, ch. 13 (see BIBLIO.md). Rendered half-res, composited additively.

// Uniforms — memory layout identical to `GodRayUniforms` in Renderer.swift.
struct GodRayUniforms {
    float4 camRight;      // camera→world basis (gaze: yaw + pitch)
    float4 camUp;
    float4 camForward;
    float4 camera;        // x: tan(FOV/2); y: aspect (width/height)
    float4 sunDirection;  // xyz: world direction TO the sun
    float4 sunColor;      // xyz: display-referred sun colour (0 below horizon)
    float4 params;        // x: density; y: decay; z: weight; w: intensity
};

struct GodRaysInOut {
    float4 position [[position]];
    float2 uv;  // top-left origin, matching the half-res offscreen targets
};

vertex GodRaysInOut god_rays_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 p = positions[vertexID];
    GodRaysInOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

// Number of radial taps from each pixel toward the sun. Half-res, one texture
// read per tap — cheap relative to the sky/cloud raymarch.
constant int kSamples = 48;
// Soft source footprint around the sun (in aspect-corrected screen units). The
// radial decay handles the shaft length; this sets how broad the source is.
constant float kGlowSigma = 0.09f;

fragment float4 god_rays_fragment(GodRaysInOut in [[stage_in]],
                                  constant GodRayUniforms &u [[buffer(0)]],
                                  texture2d<float> cloud [[texture(0)]]) {
    constexpr sampler upsample(address::clamp_to_edge, filter::linear);

    const float tanHalfFov = u.camera.x;
    const float aspect = u.camera.y;
    const float3 sunDir = normalize(u.sunDirection.xyz);

    // Project the sun into screen UV by inverting Background.metal's view-ray
    // formula: rayDir ∝ ndc.x·tanHalfFov·aspect·camRight + ndc.y·tanHalfFov·camUp
    // + camForward. With an orthonormal basis, decompose sunDir and normalise by
    // its forward component.
    const float f = dot(sunDir, u.camForward.xyz);
    if (f <= 0.0) {
        return float4(0.0);  // sun behind the camera → no shafts
    }
    const float r = dot(sunDir, u.camRight.xyz);
    const float uc = dot(sunDir, u.camUp.xyz);
    const float2 ndc = float2(r / (f * tanHalfFov * aspect), uc / (f * tanHalfFov));
    const float2 sunUV = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);

    const float density = u.params.x;
    const float decay = u.params.y;
    const float weight = u.params.z;
    const float intensity = u.params.w;

    // March from this pixel toward the sun, sampling the masked source.
    const float2 delta = (in.uv - sunUV) * (density / float(kSamples));
    float2 coord = in.uv;
    float decayFactor = 1.0;
    float accum = 0.0;
    const float glowK = 1.0 / (2.0 * kGlowSigma * kGlowSigma);
    for (int i = 0; i < kSamples; ++i) {
        coord -= delta;
        // Aspect-corrected distance to the sun → circular glow on screen.
        const float2 d = float2((coord.x - sunUV.x) * aspect, coord.y - sunUV.y);
        const float glow = exp(-dot(d, d) * glowK);
        // Cloud coverage is stored in the (premultiplied) alpha: transmittance =
        // 1 - alpha. The source survives only where light gets through.
        const float transmittance = 1.0 - cloud.sample(upsample, coord).a;
        accum += glow * transmittance * decayFactor * weight;
        decayFactor *= decay;
    }

    // Tint by the sun's display colour (zero below the horizon → free night
    // gate) and scale by the subtle intensity. Additive in the composite pass.
    return float4(u.sunColor.xyz * (accum * intensity), 0.0);
}
