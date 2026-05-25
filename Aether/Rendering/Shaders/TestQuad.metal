#include <metal_stdlib>
using namespace metal;

// Test quad for pipeline step 1: a centered quad composited over the landscape
// background, proving the multi-pass + alpha-blending path before real clouds
// arrive (step 2+).

struct QuadInOut {
    float4 position [[position]];
    float2 uv;
};

// Centered quad built from a 4-vertex triangle strip — no vertex buffer needed.
vertex QuadInOut testquad_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-0.45, -0.45),
        float2( 0.45, -0.45),
        float2(-0.45,  0.45),
        float2( 0.45,  0.45)
    };
    const float2 p = positions[vertexID];
    QuadInOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * 0.5 + 0.5;
    return out;
}

// UV gradient, semi-transparent so the landscape shows through the composite.
fragment float4 testquad_fragment(QuadInOut in [[stage_in]]) {
    return float4(in.uv.x, in.uv.y, 0.5, 0.55);
}
