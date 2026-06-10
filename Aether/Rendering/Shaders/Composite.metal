#include <metal_stdlib>
using namespace metal;

// Fullscreen-triangle sample pass, used for every composition draw: sky+sea
// and cloud "over" blends, god rays (additive), and the final copy of the
// MetalFX-upscaled composite to the drawable. On the bilinear fallback path
// the sampler also performs the half→full upsample; on the MetalFX path all
// reads are 1:1 and the spatial scaler does the only upscale.

struct CompositeInOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeInOut composite_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 p = positions[vertexID];
    CompositeInOut out;
    out.position = float4(p, 0.0, 1.0);
    // Screen-space UV with top-left origin, matching the offscreen cloud target.
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

fragment float4 composite_fragment(CompositeInOut in [[stage_in]],
                                   texture2d<float> cloud [[texture(0)]]) {
    constexpr sampler upsample(address::clamp_to_edge, filter::linear);
    return cloud.sample(upsample, in.uv);  // premultiplied → blended over background
}
