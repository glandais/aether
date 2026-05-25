#include <metal_stdlib>
using namespace metal;

// Pipeline step 4: stamp the user's brush strokes into a 3D density volume.
// Each "dab" is one painted point in the 2D canvas ([0,1]²); the silhouette is
// extruded through the volume's depth with a rounded profile so the cloud has
// thickness. The raymarch (Cloud.metal) reads this volume as the cloud's shape.

struct Dab {
    float2 center;    // canvas position, [0,1]² (top-left origin)
    float  radius;    // canvas-space radius
    float  softness;  // 0 = hard edge, 1 = very soft
};

kernel void paint_density_volume(texture3d<float, access::write> volume [[texture(0)]],
                                 constant Dab *dabs [[buffer(0)]],
                                 constant uint &count [[buffer(1)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 dims = uint3(volume.get_width(), volume.get_height(), volume.get_depth());
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
        float dist = distance(canvas, d.center);
        float inner = d.radius * (1.0f - d.softness);
        float c = 1.0f - smoothstep(inner, d.radius, dist);
        coverage = max(coverage, c);
    }

    volume.write(float4(coverage * depthProfile), gid);
}
