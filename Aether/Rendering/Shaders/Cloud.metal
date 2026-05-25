#include <metal_stdlib>
using namespace metal;

// Pipeline step 3: raymarch a single cloud whose density now comes from a
// precomputed 3D Perlin-Worley volume texture (see CloudNoise.metal) instead of
// in-shader analytic fBm. A spherical falloff still confines the cloud; the
// texture supplies the billowy base (R) and the Worley detail (GBA) that erodes
// the edges, following Schneider 2015 / Häggström. View-ray transmittance is
// Beer-Lambert (Scratchapixel); the light-march toward a fixed sun gives
// self-shadowing. Henyey-Greenstein phase, powder and atmospheric scattering
// remain deferred to step 5.

struct CloudUniforms {
    float2 resolution;
    float  time;
    float  aspect;
    float4 sunDirection;  // xyz: normalized direction TOWARD the sun
};

struct CloudInOut {
    float4 position [[position]];
    float2 ndc;           // clip-space xy, interpolated across the screen
};

constant float3 kCloudCenter = float3(0.0f, 0.7f, -5.0f);
constant float  kCloudRadius = 1.0f;
constant float  kNoiseScale = 0.42f;   // world units → texture-space frequency

constant float kSigma = 11.0f;         // extinction coefficient
constant int   kViewSteps = 64;
constant int   kLightSteps = 6;
constant float kLightStep = 0.15f;

// Linear, repeating sampler so the tileable noise wraps without seams.
constexpr sampler noiseSampler(address::repeat, filter::linear, mip_filter::none);

static inline float remap(float v, float l0, float h0, float l1, float h1) {
    return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
}

// Density from the spherical shape eroded by the 3D noise texture. Returns [0,1].
static inline float cloudDensity(float3 p, float time, texture3d<float> noise) {
    float dist = length(p - kCloudCenter);
    float shape = saturate(1.0f - dist / kCloudRadius);
    if (shape <= 0.0f) {
        return 0.0f;
    }

    // Slow drift gives the cloud a contemplative, breathing quality.
    float3 uvw = (p - kCloudCenter) * kNoiseScale + 0.5f
               + float3(time * 0.01f, time * 0.004f, time * 0.006f);
    float4 n = noise.sample(noiseSampler, uvw);

    // Base: Perlin-Worley confined by the spherical coverage.
    float base = saturate(remap(n.r, 1.0f - shape, 1.0f, 0.0f, 1.0f));

    // Detail: Worley FBM erodes the base, more strongly toward the edges.
    float detail = n.g * 0.625f + n.b * 0.25f + n.a * 0.125f;
    float density = remap(base, detail * 0.55f, 1.0f, 0.0f, 1.0f);
    return saturate(density);
}

// Beer-Lambert transmittance toward the sun (self-shadowing).
static inline float lightTransmittance(float3 p, float3 sunDir, float time, texture3d<float> noise) {
    float opticalDepth = 0.0f;
    for (int i = 0; i < kLightSteps; ++i) {
        float3 q = p + sunDir * (float(i) + 0.5f) * kLightStep;
        opticalDepth += cloudDensity(q, time, noise) * kLightStep;
    }
    return exp(-opticalDepth * kSigma);
}

// Intersect a ray with the cloud's bounding sphere. Returns near/far t in .xy,
// .z < 0 when the ray misses.
static inline float3 intersectBounds(float3 ro, float3 rd) {
    float3 oc = ro - kCloudCenter;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - kCloudRadius * kCloudRadius;
    float h = b * b - c;
    if (h < 0.0f) {
        return float3(0.0f, 0.0f, -1.0f);
    }
    h = sqrt(h);
    return float3(-b - h, -b + h, 1.0f);
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
                               texture3d<float> noise [[texture(0)]]) {
    // Fixed pinhole camera at the origin looking down -Z.
    float2 ndc = float2(in.ndc.x * u.aspect, in.ndc.y);
    float3 ro = float3(0.0f, 0.0f, 0.0f);
    float3 rd = normalize(float3(ndc * 0.5f, -1.0f));  // ~53° vertical FOV

    float3 bounds = intersectBounds(ro, rd);
    if (bounds.z < 0.0f || bounds.y < 0.0f) {
        return float4(0.0f);  // ray misses the cloud → fully transparent
    }

    float tNear = max(bounds.x, 0.0f);
    float tFar = bounds.y;
    float stepSize = (tFar - tNear) / float(kViewSteps);

    float3 sunDir = normalize(u.sunDirection.xyz);
    const float3 sunColor = float3(1.45f, 1.05f, 0.78f);   // warm dusk light
    const float3 skyAmbient = float3(0.26f, 0.32f, 0.46f); // cool sky fill

    float transmittance = 1.0f;
    float3 scattered = float3(0.0f);

    for (int i = 0; i < kViewSteps; ++i) {
        float t = tNear + (float(i) + 0.5f) * stepSize;
        float3 p = ro + rd * t;

        float density = cloudDensity(p, u.time, noise);
        if (density > 0.001f) {
            float light = lightTransmittance(p, sunDir, u.time, noise);
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
