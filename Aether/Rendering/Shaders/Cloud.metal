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
    float4 weather;         // x: coverage bias, y: density scale (from weather)
    float4 camera;          // x: tan(vertical FOV / 2) — matches the photo's zoom
};

// Temporal amortization (step 7): each frame raymarches only the half-res
// pixels whose 2×2 cell index matches `activeIndex`; the rest reuse history.
struct CloudTemporal {
    uint activeIndex;       // 0…3, cycles over frames
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
constant float kSoftDepth = 0.5f;      // soft-particle fade range near the relief

// Painted density: clamp at the edges. Noise: repeat (tileable, seamless).
constexpr sampler shapeSampler(address::clamp_to_edge, filter::linear);
constexpr sampler noiseSampler(address::repeat, filter::linear, mip_filter::none);
constexpr sampler depthSampler(address::clamp_to_edge, filter::nearest);

static inline float remap(float v, float l0, float h0, float l1, float h1) {
    return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
}

// Henyey-Greenstein phase function (normalized by 1/4π). g > 0 = forward
// scattering, g < 0 = backward.
static inline float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0f + g2 - 2.0f * g * cosTheta;
    return (1.0f - g2) / (4.0f * M_PI_F * pow(max(denom, 1.0e-4f), 1.5f));
}

// Dual-lobe phase: a strong forward lobe (dusk "silver lining" when looking
// toward the sun) blended with a softer backward lobe for ambient fill.
// `gScale` softens the anisotropy for the higher multiple-scattering octaves.
static inline float dualPhase(float cosTheta, float gScale) {
    float forward = henyeyGreenstein(cosTheta, 0.82f * gScale);
    float backward = henyeyGreenstein(cosTheta, -0.18f * gScale);
    return mix(backward, forward, 0.55f);
}

// Schneider's "powder" approximation: darkens low-density regions facing the
// light, recovering the dark edges of sunlit clouds.
static inline float powder(float density) {
    return 1.0f - exp(-density * 3.0f);
}

// Density at world point `p`: painted shape from `shape`, detailed by `noise`.
// `coverageBias` (from the weather) fills out or erodes the painted silhouette.
static inline float cloudDensity(float3 p, float time, float coverageBias,
                                 texture3d<float> shape, texture3d<float> noise,
                                 float3 boxMin, float3 boxSize) {
    float3 uvw = (p - boxMin) / boxSize;
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) {
        return 0.0f;
    }
    float painted = saturate(shape.sample(shapeSampler, uvw).r + coverageBias);
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

// Accumulated density toward the sun (optical depth before extinction), used by
// the multiple-scattering octaves below.
static inline float lightOpticalDepth(float3 p, float3 sunDir, float time, float coverageBias,
                                      texture3d<float> shape, texture3d<float> noise,
                                      float3 boxMin, float3 boxSize) {
    float opticalDepth = 0.0f;
    for (int i = 0; i < kLightSteps; ++i) {
        float3 q = p + sunDir * (float(i) + 0.5f) * kLightStep;
        opticalDepth += cloudDensity(q, time, coverageBias, shape, noise, boxMin, boxSize) * kLightStep;
    }
    return opticalDepth;
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
                               constant CloudTemporal &temporal [[buffer(1)]],
                               texture3d<float> shape [[texture(0)]],
                               texture3d<float> noise [[texture(1)]],
                               texture2d<float> sceneDepth [[texture(2)]],
                               texture2d<float, access::read> history [[texture(3)]]) {
    // Temporal amortization: only the active 2×2 cell is raymarched this frame;
    // the others reuse the previous frame (camera is fixed → same pixel).
    uint2 px = uint2(in.position.xy);
    uint cellIndex = (px.y & 1) * 2 + (px.x & 1);
    if (cellIndex != temporal.activeIndex) {
        return history.read(px);
    }

    // Pinhole camera at the origin looking down -Z, with the photo's vertical
    // FOV (zoom). `ndc.x` scaled by aspect for square pixels.
    float2 ndc = float2(in.ndc.x * u.aspect, in.ndc.y);
    float3 ro = float3(0.0f, 0.0f, 0.0f);
    float3 rd = normalize(float3(ndc * u.camera.x, -1.0f));

    float3 boxMin = u.volumeCenter.xyz - u.volumeHalfSize.xyz;
    float3 boxMax = u.volumeCenter.xyz + u.volumeHalfSize.xyz;
    float3 boxSize = boxMax - boxMin;

    float2 hit = intersectBox(ro, rd, boxMin, boxMax);
    float tNear = max(hit.x, 0.0f);
    float tFar = hit.y;

    // Scene depth (distance to the landscape along the ray): the cloud must not
    // accumulate behind the relief. Far for the sky, near for the foreground.
    float2 screenUV = float2(in.ndc.x * 0.5f + 0.5f, (1.0f - in.ndc.y) * 0.5f);
    float sceneT = sceneDepth.sample(depthSampler, screenUV).r;
    tFar = min(tFar, sceneT);

    if (tFar <= tNear) {
        // Ray misses the volume, or the relief occludes it entirely.
        return float4(0.0f);
    }

    float stepSize = (tFar - tNear) / float(kViewSteps);
    float3 sunDir = normalize(u.sunDirection.xyz);

    // Bright warm sun (compensates the 1/4π phase normalization) + cool sky fill.
    const float3 sunColor = float3(6.5f, 4.7f, 3.4f);
    const float3 skyAmbient = float3(0.34f, 0.40f, 0.55f);
    const int kScatterOctaves = 3;

    float cosTheta = dot(rd, sunDir);

    // Météo (étape 9) : biais de couverture sur la silhouette + échelle d'opacité.
    float coverageBias = u.weather.x;
    float sigma = kSigma * u.weather.y;

    float transmittance = 1.0f;
    float3 scattered = float3(0.0f);

    for (int i = 0; i < kViewSteps; ++i) {
        float t = tNear + (float(i) + 0.5f) * stepSize;
        float3 p = ro + rd * t;

        float density = cloudDensity(p, u.time, coverageBias, shape, noise, boxMin, boxSize);
        // Soft particles: fade the cloud as it approaches the relief, avoiding a
        // hard intersection edge (depth maps are imprecise — see BIBLIO §4).
        density *= smoothstep(0.0f, kSoftDepth, sceneT - t);
        if (density > 0.001f) {
            float opticalDepth = lightOpticalDepth(p, sunDir, u.time, coverageBias, shape, noise, boxMin, boxSize);

            // Multiple-scattering approximation (Hillaire / Wrenninge octaves):
            // each octave lets light penetrate deeper (lower extinction) with a
            // smaller, more isotropic contribution — so backlit clouds glow.
            float3 sunLight = float3(0.0f);
            float attenuation = 1.0f;
            float weight = 1.0f;
            float gScale = 1.0f;
            for (int o = 0; o < kScatterOctaves; ++o) {
                float beer = exp(-opticalDepth * sigma * attenuation);
                sunLight += weight * beer * dualPhase(cosTheta, gScale);
                attenuation *= 0.5f;
                weight *= 0.55f;
                gScale *= 0.5f;
            }
            sunLight *= sunColor * powder(density);

            float3 luminance = sunLight + skyAmbient;
            float extinction = density * sigma * stepSize;
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
