#include <metal_stdlib>
using namespace metal;

// Multi-shell model (docs/SHELLS.md §5): stamp the user's brush strokes into a
// directional coverage map — a 2D equirectangular atlas of the upper hemisphere,
// one slice per painted layer. Each "dab" is one painted point in the 2D canvas
// ([0,1]², top-left origin) recorded with the camera pose at paint time. For each
// texel (a sky direction) we project that direction into the paint-time camera
// and test the dabs in screen space — so a stroke deposits where the screen ray
// pointed, and stays put when the gaze later rotates. The shell raymarch
// (Cloud.metal) samples this map once per shell per pixel.
//
// `stamp_coverage_map` max-combines the dabs with the existing coverage; the
// Renderer only re-dispatches the new dabs (or a full per-layer rebuild on
// undo/clear). Ping-pong (read `src`, write `dst`) keeps the atlas R8Unorm,
// which is filterable on iOS GPUs (R32Float is not, so linear sampling would fall
// back to nearest → blocky clouds on device).

struct Dab {
    float2 center;    // canvas position, [0,1]² (top-left origin)
    float  radius;    // canvas-space radius
    float  softness;  // 0 = hard edge, 1 = very soft
};

// MARK: - Directional coverage map (multi-shell model, docs/SHELLS.md §5)

// Paint-time camera pose for the coverage stamp. Mirrors `CoverageStampUniforms`
// in Renderer.swift. There is no world box and no depth plane: the shell raymarch
// samples a 2D coverage map indexed by *direction*, so the stamp only needs the
// paint-time camera basis to project a sky direction back to the painted canvas.
struct CoverageStampUniforms {
    float4 camRight;    // paint-time camera→world basis
    float4 camUp;
    float4 camForward;
    float4 params;      // x: tan(FOV/2), y: aspect, z: target layer (array slice)
};

// Stamp brush dabs into one slice of the directional coverage atlas. The atlas is
// an equirectangular map of the upper hemisphere: U spans azimuth [-180°,180°]
// (-Z = North), V spans elevation [0°,90°]. Each texel is a sky direction; we
// project that direction into the paint-time camera and test the dabs in canvas
// space — a perspective screen→canvas projection (coverage is a 2D directional
// field, with no world box and no depth profile).
//
// Nothing is deposited below the horizon: the map domain stops at elevation 0, so
// a dab straddling the horizon only deposits its part at el >= 0 (the texels below
// the domain simply don't exist). Combination is additive via max(existing, …);
// the Renderer re-dispatches only new dabs.
kernel void stamp_coverage_map(texture2d_array<float, access::read> src [[texture(0)]],
                               texture2d_array<float, access::write> dst [[texture(1)]],
                               constant Dab *dabs [[buffer(0)]],
                               constant uint &count [[buffer(1)]],
                               constant CoverageStampUniforms &U [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint2 dims = uint2(dst.get_width(), dst.get_height());
    if (any(gid >= dims)) {
        return;
    }
    uint layer = uint(U.params.z);

    // Texel-centric: this texel's sky direction. U → azimuth, V → elevation, both
    // in the upper hemisphere only (V ∈ [0,1] maps to el ∈ [0°,90°]).
    float2 uv = (float2(gid) + 0.5f) / float2(dims);
    float az = (uv.x - 0.5f) * 2.0f * M_PI_F;   // azimuth, 0 = North (-Z)
    float el = uv.y * (M_PI_F * 0.5f);          // elevation, upper hemisphere
    float ce = cos(el);
    float3 dir = float3(sin(az) * ce, sin(el), -cos(az) * ce);

    // Carry the existing coverage forward (ping-pong keeps both slices in sync).
    float existing = src.read(gid, layer).r;

    // Project into the paint-time camera (eye at the origin). `forward` is the
    // look direction, so a direction in front has zc > 0.
    float xc = dot(dir, U.camRight.xyz);
    float yc = dot(dir, U.camUp.xyz);
    float zc = dot(dir, U.camForward.xyz);

    float coverage = 0.0f;
    if (zc > 1.0e-4f) {
        const float tanHalfFov = U.params.x;
        const float aspect = U.params.y;

        // Perspective project to clip-space NDC, then to top-left canvas UV
        // (inverse of `cloud_vertex`'s screen normalization).
        float ndcX = (xc / zc) / (tanHalfFov * aspect);
        float ndcY = (yc / zc) / tanHalfFov;
        float2 canvas = float2(ndcX * 0.5f + 0.5f, 0.5f - ndcY * 0.5f);

        for (uint i = 0; i < count; ++i) {
            Dab dab = dabs[i];
            // Screen-proportional metric: the canvas U axis spans `aspect` units
            // per V unit, so `radius` (a V-axis fraction) projects to a circle.
            float2 delta = canvas - dab.center;
            delta.x *= aspect;
            float dist = length(delta);
            float inner = dab.radius * (1.0f - dab.softness);
            float c = 1.0f - smoothstep(inner, dab.radius, dist);
            coverage = max(coverage, c);
        }
    }

    // Max-combine the new dabs with the existing coverage in this slice.
    dst.write(float4(max(existing, coverage)), gid, layer);
}

// Clear every slice of the coverage atlas to zero (empty sky, no painted cover).
kernel void clear_coverage_map(texture2d_array<float, access::write> atlas [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint2 dims = uint2(atlas.get_width(), atlas.get_height());
    if (any(gid >= dims)) {
        return;
    }
    for (uint layer = 0; layer < atlas.get_array_size(); ++layer) {
        atlas.write(float4(0.0f), gid, layer);
    }
}
