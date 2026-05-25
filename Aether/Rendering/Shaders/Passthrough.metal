#include <metal_stdlib>
using namespace metal;

// Test quad shader, kept ready for pipeline step 1 (background texture + test
// quad) and step 2 (analytic cloud). Not yet wired by the Renderer, which only
// clears the screen for now.

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle generated from the vertex id — no vertex buffer needed.
vertex VertexOut passthrough_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

fragment float4 passthrough_fragment(VertexOut in [[stage_in]]) {
    return float4(in.uv, 0.0, 1.0);
}
