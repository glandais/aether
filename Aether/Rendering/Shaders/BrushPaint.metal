#include <metal_stdlib>
using namespace metal;

// Pipeline step 4 (+ incremental repaint): stamp the user's brush strokes into a
// 3D density volume. Each "dab" is one painted point in the 2D canvas ([0,1]²);
// the silhouette is extruded through the volume's depth with a rounded profile
// so the cloud has thickness. The raymarch (Cloud.metal) reads this volume.
//
// `stamp_density_volume` only adds the NEW dabs since the last update and
// max-combines them with the existing volume — so a long stroke costs O(new
// dabs), not O(all dabs), per frame. Ping-pong (read `src`, write `dst`) keeps
// the volume R8Unorm, which is filterable on iOS GPUs (R32Float is not, so
// linear sampling would fall back to nearest → blocky clouds on device).

struct Dab {
    float2 center;    // canvas position, [0,1]² (top-left origin)
    float  radius;    // canvas-space radius
    float  softness;  // 0 = hard edge, 1 = very soft
};

kernel void stamp_density_volume(texture3d<float, access::read> src [[texture(0)]],
                                 texture3d<float, access::write> dst [[texture(1)]],
                                 constant Dab *dabs [[buffer(0)]],
                                 constant uint &count [[buffer(1)]],
                                 constant float &aspect [[buffer(2)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 dims = uint3(dst.get_width(), dst.get_height(), dst.get_depth());
    if (any(gid >= dims)) {
        return;
    }

    float3 uvw = (float3(gid) + 0.5f) / float3(dims);
    // Volume Y is world-up; the canvas V axis points down → flip.
    float2 canvas = float2(uvw.x, 1.0f - uvw.y);

    // Rounded falloff through depth: full at the mid-plane, zero at the faces.
    float zc = uvw.z * 2.0f - 1.0f;
    float depthProfile = saturate(1.0f - zc * zc);

    float coverage = 0.0f;
    for (uint i = 0; i < count; ++i) {
        Dab d = dabs[i];
        // Measure distance in a screen-proportional metric: the canvas U axis
        // spans `aspect` (= drawable width/height) world units per V unit, so
        // scaling the U delta makes `radius` (a V-axis fraction) project to a
        // circle on screen regardless of orientation.
        float2 delta = canvas - d.center;
        delta.x *= aspect;
        float dist = length(delta);
        float inner = d.radius * (1.0f - d.softness);
        float c = 1.0f - smoothstep(inner, d.radius, dist);
        coverage = max(coverage, c);
    }

    // Carry the existing density forward, max-combined with the new dabs.
    float existing = src.read(gid).r;
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
