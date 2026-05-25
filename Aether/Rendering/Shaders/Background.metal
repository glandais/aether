#include <metal_stdlib>
using namespace metal;

// Background pass for pipeline step 1: draws the landscape as a fullscreen
// texture. Later steps composite the volumetric clouds and a depth map on top.

struct BackgroundInOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle generated from the vertex id — no vertex buffer needed.
// UV is flipped on Y so the texture (top-left origin) appears upright.
vertex BackgroundInOut background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 p = positions[vertexID];
    BackgroundInOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
    return out;
}

fragment float4 background_fragment(BackgroundInOut in [[stage_in]],
                                    texture2d<float> landscape [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
    return landscape.sample(smp, in.uv);
}
