#include <metal_stdlib>
using namespace metal;

// Pipeline step 4 (+ world-fixed volume): stamp the user's brush strokes into a
// 3D density volume that lives at a real position in the world (anchored along
// the scene's base view direction, independent of the live gaze). Each "dab" is
// one painted point in the 2D canvas ([0,1]², top-left origin) recorded with the
// camera pose at paint time. For each voxel we project its WORLD position into
// that paint-time camera and test the dabs in screen space — so a stroke deposits
// where the screen ray pierced the box, and stays put when the gaze later rotates.
//
// Thickness along the view ray comes from a Gaussian centred on the box's depth
// plane (without it, projecting a 2D dab would paint an infinite tube through the
// whole box). The raymarch (Cloud.metal) reads this volume.
//
// `stamp_density_volume` max-combines the dabs with the existing volume; the
// Renderer only re-dispatches the new dabs (or a full per-stroke rebuild on
// undo/clear). Ping-pong (read `src`, write `dst`) keeps the volume R8Unorm,
// which is filterable on iOS GPUs (R32Float is not, so linear sampling would fall
// back to nearest → blocky clouds on device).

struct Dab {
    float2 center;    // canvas position, [0,1]² (top-left origin)
    float  radius;    // canvas-space radius
    float  softness;  // 0 = hard edge, 1 = very soft
};

// World box + paint-time camera pose. Mirrors `StampUniforms` in Renderer.swift.
// The density texture is an ATLAS: `CloudCube.maxCount` slabs of `slab.y` voxels stacked in
// depth, one per cloud cube. A stamp writes one slab (`slab.x`) and copies the
// rest through, so the ping-pong flip keeps every other cube intact.
struct StampUniforms {
    float4 boxMin;     // xyz: world AABB min corner
    float4 boxSize;    // xyz: world AABB size
    float4 boxCenter;  // xyz: world centre (the stroke's depth plane)
    float4 camRight;   // paint-time camera→world basis
    float4 camUp;
    float4 camForward;
    float4 params;     // x: tan(FOV/2), y: aspect, z: depth sigma (world units)
    float4 slab;       // x: target slab index, y: slab depth (voxels)
};

kernel void stamp_density_volume(texture3d<float, access::read> src [[texture(0)]],
                                 texture3d<float, access::write> dst [[texture(1)]],
                                 constant Dab *dabs [[buffer(0)]],
                                 constant uint &count [[buffer(1)]],
                                 constant StampUniforms &U [[buffer(2)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 dims = uint3(dst.get_width(), dst.get_height(), dst.get_depth());
    if (any(gid >= dims)) {
        return;
    }

    // Carry the existing density forward. Voxels outside the target slab are just
    // copied (they belong to other cubes) — this keeps them across the ping-pong.
    float existing = src.read(gid).r;
    uint slabDepth = uint(U.slab.y);
    uint slabBase = uint(U.slab.x) * slabDepth;
    if (gid.z < slabBase || gid.z >= slabBase + slabDepth) {
        dst.write(float4(existing), gid);
        return;
    }

    // World position of this voxel within the cube's AABB. The cube occupies one
    // slab, so normalize against the slab (local z), not the whole atlas.
    uint3 local = uint3(gid.x, gid.y, gid.z - slabBase);
    float3 sdims = float3(float(dims.x), float(dims.y), float(slabDepth));
    float3 uvw = (float3(local) + 0.5f) / sdims;
    float3 p = U.boxMin.xyz + uvw * U.boxSize.xyz;

    // Project into the paint-time camera (eye at the origin). `forward` is the
    // look direction, so a voxel in front has zc > 0.
    float xc = dot(p, U.camRight.xyz);
    float yc = dot(p, U.camUp.xyz);
    float zc = dot(p, U.camForward.xyz);

    float coverage = 0.0f;
    float depthProfile = 0.0f;
    if (zc > 1.0e-4f) {
        const float tanHalfFov = U.params.x;
        const float aspect = U.params.y;
        const float depthSigma = U.params.z;

        // Perspective project to clip-space NDC, then to top-left canvas UV
        // (inverse of `cloud_vertex` / `paint()`'s screen normalization).
        float ndcX = (xc / zc) / (tanHalfFov * aspect);
        float ndcY = (yc / zc) / tanHalfFov;
        float2 canvas = float2(ndcX * 0.5f + 0.5f, 0.5f - ndcY * 0.5f);

        // Thickness along the view ray: Gaussian about the box's depth plane.
        float centerDepth = dot(U.boxCenter.xyz, U.camForward.xyz);
        float d = zc - centerDepth;
        depthProfile = exp(-(d * d) / (2.0f * depthSigma * depthSigma));

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

    // Max-combine the new dabs with the existing density in this slab.
    dst.write(float4(max(existing, coverage * depthProfile)), gid);
}

kernel void clear_density_volume(texture3d<float, access::write> volume [[texture(0)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 dims = uint3(volume.get_width(), volume.get_height(), volume.get_depth());
    if (any(gid >= dims)) {
        return;
    }
    volume.write(float4(0.0f), gid);
}
