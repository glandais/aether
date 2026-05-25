#include <metal_stdlib>
using namespace metal;

// Pipeline step 7: upsample the half-resolution cloud target and composite it
// over the full-resolution landscape. The cloud was rendered offscreen (half
// res, temporally amortized); here it is sampled with bilinear filtering and
// blended "over" the background with premultiplied alpha.

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
