#include <metal_stdlib>
using namespace metal;

// Pipeline step 3: bake a tileable 3D Perlin-Worley noise texture in a compute
// pass (Schneider 2015 / Häggström / Bitsquid). Channel layout follows the
// Nubis "shape" texture:
//   R = Perlin-Worley (low-frequency billowy base)
//   G = Worley, frequency  6
//   B = Worley, frequency 12   (detail, erodes the base in the raymarch)
//   A = Worley, frequency 24

static inline float3 hash33(float3 p) {
    p = float3(dot(p, float3(127.1f, 311.7f, 74.7f)),
               dot(p, float3(269.5f, 183.3f, 246.1f)),
               dot(p, float3(113.5f, 271.9f, 124.6f)));
    return fract(sin(p) * 43758.5453123f);
}

// Positive modulo so lattice coordinates wrap cleanly → tileable noise.
static inline float3 wrap(float3 c, float period) {
    return fract(c / period) * period;
}

// Tileable 3D gradient (Perlin) noise, remapped to [0, 1].
static inline float perlin3(float3 p, float frequency) {
    p *= frequency;
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);  // quintic fade

    float d[8];
    int k = 0;
    for (int z = 0; z <= 1; ++z) {
        for (int y = 0; y <= 1; ++y) {
            for (int x = 0; x <= 1; ++x) {
                float3 corner = float3(float(x), float(y), float(z));
                float3 g = normalize(hash33(wrap(i + corner, frequency)) * 2.0f - 1.0f);
                d[k++] = dot(g, f - corner);
            }
        }
    }
    float nx00 = mix(d[0], d[1], u.x);
    float nx10 = mix(d[2], d[3], u.x);
    float nx01 = mix(d[4], d[5], u.x);
    float nx11 = mix(d[6], d[7], u.x);
    float nxy0 = mix(nx00, nx10, u.y);
    float nxy1 = mix(nx01, nx11, u.y);
    return mix(nxy0, nxy1, u.z) * 0.5f + 0.5f;
}

// Tileable 3D Worley (cellular) noise, inverted so cells read bright in [0, 1].
static inline float worley3(float3 p, float frequency) {
    p *= frequency;
    float3 id = floor(p);
    float3 f = fract(p);
    float minDistSq = 1.0e9f;
    for (int z = -1; z <= 1; ++z) {
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                float3 offset = float3(float(x), float(y), float(z));
                float3 cell = wrap(id + offset, frequency);
                float3 feature = hash33(cell);
                float3 diff = offset + feature - f;
                minDistSq = min(minDistSq, dot(diff, diff));
            }
        }
    }
    return saturate(1.0f - sqrt(minDistSq));
}

static inline float perlinFBM(float3 p, float frequency) {
    return perlin3(p, frequency) * 0.5f
         + perlin3(p, frequency * 2.0f) * 0.25f
         + perlin3(p, frequency * 4.0f) * 0.125f;
}

static inline float worleyFBM(float3 p, float frequency) {
    return worley3(p, frequency) * 0.625f
         + worley3(p, frequency * 2.0f) * 0.25f
         + worley3(p, frequency * 4.0f) * 0.125f;
}

static inline float remap(float v, float l0, float h0, float l1, float h1) {
    return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
}

kernel void generate_cloud_noise(texture3d<float, access::write> outTexture [[texture(0)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 dims = uint3(outTexture.get_width(), outTexture.get_height(), outTexture.get_depth());
    if (any(gid >= dims)) {
        return;
    }
    float3 p = (float3(gid) + 0.5f) / float3(dims);  // [0, 1) cube

    // R: Perlin-Worley — Perlin shaped by low-frequency Worley FBM.
    float pfbm = perlinFBM(p, 4.0f);
    float wfbm = worleyFBM(p, 4.0f);
    float perlinWorley = saturate(remap(pfbm, wfbm - 1.0f, 1.0f, 0.0f, 1.0f));

    // G/B/A: Worley detail at rising frequencies.
    float w6 = worley3(p, 6.0f);
    float w12 = worley3(p, 12.0f);
    float w24 = worley3(p, 24.0f);

    outTexture.write(float4(perlinWorley, w6, w12, w24), gid);
}
