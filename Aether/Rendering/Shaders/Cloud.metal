#include <metal_stdlib>
using namespace metal;

// Pipeline step 4: the cloud's shape now comes from a painted 3D density volume
// (see BrushPaint.metal) instead of an analytic sphere. The raymarch confines
// itself to the volume's AABB, samples the painted density as the base shape,
// then erodes/details it with the precomputed Perlin-Worley noise (step 3,
// CloudNoise.metal), following Schneider's authoring model. View-ray
// transmittance is Beer-Lambert (Scratchapixel); the light-march toward a fixed
// sun gives self-shadowing. Henyey-Greenstein phase, powder and atmospheric
// scattering remain deferred to step 5.

struct CloudUniforms {
    float2 resolution;
    float  time;
    float  aspect;
    float4 sunDirection;    // xyz: normalized direction TOWARD the sun
    float4 volumeCenter;    // xyz: world-space center of the density volume
    float4 volumeHalfSize;  // xyz: world-space half-extents of the volume AABB
};

struct CloudInOut {
    float4 position [[position]];
    float2 ndc;             // clip-space xy, interpolated across the screen
};

constant float kNoiseScale = 0.42f;    // world units → noise texture frequency
constant float kSigma = 11.0f;         // extinction coefficient
constant int   kViewSteps = 64;
constant int   kLightSteps = 6;
constant float kLightStep = 0.15f;

// Painted density: clamp at the edges. Noise: repeat (tileable, seamless).
constexpr sampler shapeSampler(address::clamp_to_edge, filter::linear);
constexpr sampler noiseSampler(address::repeat, filter::linear, mip_filter::none);

static inline float remap(float v, float l0, float h0, float l1, float h1) {
    return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
}

// Density at world point `p`: painted shape from `shape`, detailed by `noise`.
static inline float cloudDensity(float3 p, float time,
                                 texture3d<float> shape, texture3d<float> noise,
                                 float3 boxMin, float3 boxSize) {
    float3 uvw = (p - boxMin) / boxSize;
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) {
        return 0.0f;
    }
    float painted = shape.sample(shapeSampler, uvw).r;
    if (painted <= 0.001f) {
        return 0.0f;
    }

    // Slow drift gives the cloud a contemplative, breathing quality.
    float3 nuvw = p * kNoiseScale
                + float3(time * 0.01f, time * 0.004f, time * 0.006f);
    float4 n = noise.sample(noiseSampler, nuvw);

    // The painted coverage shapes the Perlin-Worley base...
    float base = saturate(remap(n.r, 1.0f - painted, 1.0f, 0.0f, 1.0f));
    // ...and the Worley channels erode the detail.
    float detail = n.g * 0.625f + n.b * 0.25f + n.a * 0.125f;
    float density = remap(base, detail * 0.55f, 1.0f, 0.0f, 1.0f);
    return saturate(density);
}

// Beer-Lambert transmittance toward the sun (self-shadowing).
static inline float lightTransmittance(float3 p, float3 sunDir, float time,
                                       texture3d<float> shape, texture3d<float> noise,
                                       float3 boxMin, float3 boxSize) {
    float opticalDepth = 0.0f;
    for (int i = 0; i < kLightSteps; ++i) {
        float3 q = p + sunDir * (float(i) + 0.5f) * kLightStep;
        opticalDepth += cloudDensity(q, time, shape, noise, boxMin, boxSize) * kLightStep;
    }
    return exp(-opticalDepth * kSigma);
}

// Slab-method ray/AABB intersection. Returns near/far t in .xy.
static inline float2 intersectBox(float3 ro, float3 rd, float3 boxMin, float3 boxMax) {
    float3 invDir = 1.0f / rd;
    float3 t0 = (boxMin - ro) * invDir;
    float3 t1 = (boxMax - ro) * invDir;
    float3 tSmall = min(t0, t1);
    float3 tBig = max(t0, t1);
    float tNear = max(max(tSmall.x, tSmall.y), tSmall.z);
    float tFar = min(min(tBig.x, tBig.y), tBig.z);
    return float2(tNear, tFar);
}

vertex CloudInOut cloud_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 p = positions[vertexID];
    CloudInOut out;
    out.position = float4(p, 0.0, 1.0);
    out.ndc = p;
    return out;
}

// Outputs PREMULTIPLIED color + coverage alpha, composited over the landscape
// with (one, oneMinusSourceAlpha) blending.
fragment float4 cloud_fragment(CloudInOut in [[stage_in]],
                               constant CloudUniforms &u [[buffer(0)]],
                               texture3d<float> shape [[texture(0)]],
                               texture3d<float> noise [[texture(1)]]) {
    // Fixed pinhole camera at the origin looking down -Z.
    float2 ndc = float2(in.ndc.x * u.aspect, in.ndc.y);
    float3 ro = float3(0.0f, 0.0f, 0.0f);
    float3 rd = normalize(float3(ndc * 0.5f, -1.0f));  // ~53° vertical FOV

    float3 boxMin = u.volumeCenter.xyz - u.volumeHalfSize.xyz;
    float3 boxMax = u.volumeCenter.xyz + u.volumeHalfSize.xyz;
    float3 boxSize = boxMax - boxMin;

    float2 hit = intersectBox(ro, rd, boxMin, boxMax);
    float tNear = max(hit.x, 0.0f);
    float tFar = hit.y;
    if (tFar <= tNear) {
        return float4(0.0f);  // ray misses the volume → fully transparent
    }

    float stepSize = (tFar - tNear) / float(kViewSteps);
    float3 sunDir = normalize(u.sunDirection.xyz);
    const float3 sunColor = float3(1.45f, 1.05f, 0.78f);   // warm dusk light
    const float3 skyAmbient = float3(0.26f, 0.32f, 0.46f); // cool sky fill

    float transmittance = 1.0f;
    float3 scattered = float3(0.0f);

    for (int i = 0; i < kViewSteps; ++i) {
        float t = tNear + (float(i) + 0.5f) * stepSize;
        float3 p = ro + rd * t;

        float density = cloudDensity(p, u.time, shape, noise, boxMin, boxSize);
        if (density > 0.001f) {
            float light = lightTransmittance(p, sunDir, u.time, shape, noise, boxMin, boxSize);
            float3 luminance = sunColor * light + skyAmbient;

            float extinction = density * kSigma * stepSize;
            // In-scattered radiance integrated against current transmittance.
            scattered += transmittance * luminance * extinction;
            transmittance *= exp(-extinction);

            if (transmittance < 0.01f) {
                break;  // early-out: the cloud is opaque from here on
            }
        }
    }

    float alpha = 1.0f - transmittance;
    return float4(scattered, alpha);
}
