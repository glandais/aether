#include <metal_stdlib>
using namespace metal;

// Pipeline step 2: raymarch a single ANALYTIC cloud — a noise-eroded sphere lit
// by a fixed directional sun. View-ray transmittance follows Beer-Lambert
// (Scratchapixel, "ray marching: get it right"); the density model and the
// short light-march toward the sun follow Schneider 2015 (Nubis) / Häggström.
// The full Henyey-Greenstein phase function, powder term and atmospheric
// scattering are deferred to step 5.

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

// --- Procedural value noise + fBm (Quilez) -------------------------------

static inline float hash13(float3 p) {
    p = fract(p * 0.3183099f + float3(0.1f, 0.2f, 0.3f));
    p *= 17.0f;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Trilinearly interpolated value noise on the integer lattice.
static inline float valueNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0f - 2.0f * f);  // smoothstep weights

    float n000 = hash13(i + float3(0.0f, 0.0f, 0.0f));
    float n100 = hash13(i + float3(1.0f, 0.0f, 0.0f));
    float n010 = hash13(i + float3(0.0f, 1.0f, 0.0f));
    float n110 = hash13(i + float3(1.0f, 1.0f, 0.0f));
    float n001 = hash13(i + float3(0.0f, 0.0f, 1.0f));
    float n101 = hash13(i + float3(1.0f, 0.0f, 1.0f));
    float n011 = hash13(i + float3(0.0f, 1.0f, 1.0f));
    float n111 = hash13(i + float3(1.0f, 1.0f, 1.0f));

    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

// Fractal Brownian motion: layered octaves of value noise.
static inline float fbm(float3 p) {
    float sum = 0.0f;
    float amplitude = 0.5f;
    float frequency = 1.0f;
    for (int i = 0; i < 4; ++i) {
        sum += amplitude * valueNoise(p * frequency);
        frequency *= 2.02f;
        amplitude *= 0.5f;
    }
    return sum;
}

// --- Cloud density -------------------------------------------------------

constant float3 kCloudCenter = float3(0.0f, 0.7f, -5.0f);
constant float  kCloudRadius = 1.0f;

// Analytic density: a spherical falloff eroded by fBm. The erosion is weighted
// toward the boundary (Schneider 2015) so the core stays dense while the edges
// break into wisps. Returns [0, 1].
static inline float cloudDensity(float3 p, float time) {
    float dist = length(p - kCloudCenter);
    float shape = saturate(1.0f - dist / kCloudRadius);

    // Higher frequency than the cloud radius → fluffy detail. Slow drift gives
    // the cloud a contemplative, breathing quality.
    float3 q = p * 2.8f + float3(time * 0.03f, time * 0.008f, time * 0.015f);
    float detail = fbm(q);

    // Erode more where `shape` is small (edges), little at the core.
    float erosion = (1.0f - detail) * mix(0.95f, 0.12f, shape);
    float density = saturate(shape - erosion);
    return density;
}

// --- Raymarch ------------------------------------------------------------

constant float kSigma = 11.0f;        // extinction coefficient
constant int   kViewSteps = 64;
constant int   kLightSteps = 6;
constant float kLightStep = 0.15f;

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

// Beer-Lambert transmittance toward the sun (self-shadowing).
static inline float lightTransmittance(float3 p, float3 sunDir, float time) {
    float opticalDepth = 0.0f;
    for (int i = 0; i < kLightSteps; ++i) {
        float3 q = p + sunDir * (float(i) + 0.5f) * kLightStep;
        opticalDepth += cloudDensity(q, time) * kLightStep;
    }
    return exp(-opticalDepth * kSigma);
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
                               constant CloudUniforms &u [[buffer(0)]]) {
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

        float density = cloudDensity(p, u.time);
        if (density > 0.001f) {
            float light = lightTransmittance(p, sunDir, u.time);
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
