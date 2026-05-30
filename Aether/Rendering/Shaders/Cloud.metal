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
    float4 weather;         // x: coverage bias, y: density scale (from weather)
    float4 camera;          // x: tan(vertical FOV / 2) — matches the photo's zoom
    float4 lightSun;        // xyz: sun colour × intensity (by altitude & exposure)
    float4 lightAmbient;    // xyz: sky ambient fill
    // Camera→world basis of the gaze (yaw + pitch), shared with the sky pass.
    // The view ray is reconstructed from these so the world-fixed cloud boxes can
    // be looked around / orbited; at the identity basis it faces North (-Z).
    float4 camRight;
    float4 camUp;
    float4 camForward;
    uint   cubeCount;       // number of valid entries in the `cubes` buffer
    uint   atlasSlabs;      // total slabs stacked in the density atlas (= CloudCube.maxCount)
};

// One cloud cube: its world AABB. Mirrors `CloudCubeGPU` in Renderer.swift. Its
// painted density lives in slab `i` of the atlas (depth [i·48, (i+1)·48)).
struct CloudCubeGPU {
    float4 center;          // xyz: world-space center of the cube
    float4 halfSize;        // xyz: world-space half-extents of the cube AABB
};

// Capacity ceiling for the per-ray hit arrays in `cloud_fragment` (a compile-time
// array bound, NOT the cube count — that comes from `u.atlasSlabs`). Only needs to
// be ≥ CloudCube.maxCount; the gather clamps to it.
#define kMaxCubeHits 16

// Temporal amortization (step 7): each frame raymarches only the half-res
// pixels whose 2×2 cell index matches `activeIndex`; the rest reuse history.
struct CloudTemporal {
    uint activeIndex;       // 0…3, cycles over frames
    uint cameraMoving;      // 1 while the gaze rotates/zooms → raymarch all pixels
};

struct CloudInOut {
    float4 position [[position]];
    float2 ndc;             // clip-space xy, interpolated across the screen
};

constant float kNoiseScale = 0.42f;    // world units → noise texture frequency
constant float kSigma = 11.0f;         // extinction coefficient
constant float kBoxFeather = 0.12f;    // fade density near the AABB faces (no hard cube)
constant int   kViewSteps = 64;
constant int   kLightSteps = 6;
constant float kLightStep = 0.15f;

// Painted density: clamp at the edges. Noise: repeat (tileable, seamless).
constexpr sampler shapeSampler(address::clamp_to_edge, filter::linear);
constexpr sampler noiseSampler(address::repeat, filter::linear, mip_filter::none);

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
// `cubeIndex` selects the cube's slab in the density atlas: the local depth
// `uvw.z` is remapped into slab `cubeIndex` of `slabCount`.
static inline float cloudDensity(float3 p, float time, float coverageBias,
                                 texture3d<float> shape, texture3d<float> noise,
                                 float3 boxMin, float3 boxSize, int cubeIndex, int slabCount) {
    float3 uvw = (p - boxMin) / boxSize;
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) {
        return 0.0f;
    }
    // Address this cube's slab in the stacked atlas.
    float3 atlasUVW = float3(uvw.xy, (float(cubeIndex) + uvw.z) / float(slabCount));
    float painted = saturate(shape.sample(shapeSampler, atlasUVW).r + coverageBias);
    if (painted <= 0.001f) {
        return 0.0f;
    }

    // Feather the painted shape toward the AABB faces so the box itself is never
    // visible as a hard cube — the cloud dissolves into the sky at its bounds.
    float3 edge = min(uvw, 1.0f - uvw);
    float boxFade = smoothstep(0.0f, kBoxFeather, min(edge.x, min(edge.y, edge.z)));
    painted *= boxFade;
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
                                      float3 boxMin, float3 boxSize, int cubeIndex, int slabCount) {
    float opticalDepth = 0.0f;
    for (int i = 0; i < kLightSteps; ++i) {
        float3 q = p + sunDir * (float(i) + 0.5f) * kLightStep;
        opticalDepth += cloudDensity(q, time, coverageBias, shape, noise, boxMin, boxSize, cubeIndex, slabCount) * kLightStep;
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
                               constant CloudCubeGPU *cubes [[buffer(2)]],
                               texture3d<float> shape [[texture(0)]],
                               texture3d<float> noise [[texture(1)]],
                               texture2d<float, access::read> history [[texture(2)]]) {
    // Temporal amortization: only the active 2×2 cell is raymarched this frame;
    // the others reuse the previous frame — valid only while the camera is
    // still (same pixel = same ray). While the gaze moves the ray under each
    // pixel changes every frame, so reusing history would smear; raymarch all.
    uint2 px = uint2(in.position.xy);
    uint cellIndex = (px.y & 1) * 2 + (px.x & 1);
    if (temporal.cameraMoving == 0 && cellIndex != temporal.activeIndex) {
        return history.read(px);
    }

    // Reconstruct the world-space view ray from the camera→world basis (mirror
    // of `sky_background_fragment`), so the world-fixed cloud boxes can be looked
    // around. `in.ndc` is already clip-space (+Y up) from `cloud_vertex`.
    float2 ndc = in.ndc;
    float3 ro = float3(0.0f, 0.0f, 0.0f);
    float3 rd = normalize(
        ndc.x * u.camera.x * u.aspect * u.camRight.xyz +
        ndc.y * u.camera.x * u.camUp.xyz +
        u.camForward.xyz);

    // Gather the cubes this ray crosses (near/far t + cube index).
    int n = min(int(u.cubeCount), kMaxCubeHits);
    int slabCount = int(u.atlasSlabs);
    float hitNear[kMaxCubeHits];
    float hitFar[kMaxCubeHits];
    int   hitIdx[kMaxCubeHits];
    int   hitCount = 0;
    float totalLen = 0.0f;
    for (int i = 0; i < n; ++i) {
        float3 c = cubes[i].center.xyz;
        float3 h = cubes[i].halfSize.xyz;
        float2 hit = intersectBox(ro, rd, c - h, c + h);
        float tn = max(hit.x, 0.0f);
        float tf = hit.y;
        if (tf > tn) {
            hitNear[hitCount] = tn;
            hitFar[hitCount] = tf;
            hitIdx[hitCount] = i;
            totalLen += (tf - tn);
            hitCount++;
        }
    }
    if (hitCount == 0) {
        return float4(0.0f);  // ray misses every cube
    }

    // Sort the hit segments by near distance (insertion sort, ≤ kMaxCubeHits) so we
    // composite strictly front-to-back across cubes.
    for (int i = 1; i < hitCount; ++i) {
        float kn = hitNear[i], kf = hitFar[i];
        int ki = hitIdx[i];
        int j = i - 1;
        while (j >= 0 && hitNear[j] > kn) {
            hitNear[j + 1] = hitNear[j];
            hitFar[j + 1] = hitFar[j];
            hitIdx[j + 1] = hitIdx[j];
            j--;
        }
        hitNear[j + 1] = kn;
        hitFar[j + 1] = kf;
        hitIdx[j + 1] = ki;
    }

    // Global step budget: one uniform step size shared across every hit segment,
    // so the total marched steps stay near kViewSteps regardless of cube count.
    float stepSize = max(totalLen / float(kViewSteps), 1.0e-4f);
    float3 sunDir = normalize(u.sunDirection.xyz);

    // Scene-aware lighting: sun colour/intensity by altitude × the photo's
    // exposure, and a matching sky ambient (resolved on the CPU).
    float3 sunColor = u.lightSun.xyz;
    float3 skyAmbient = u.lightAmbient.xyz;
    const int kScatterOctaves = 3;

    float cosTheta = dot(rd, sunDir);

    // Météo (étape 9) : biais de couverture sur la silhouette + échelle d'opacité.
    float coverageBias = u.weather.x;
    float sigma = kSigma * u.weather.y;

    float transmittance = 1.0f;
    float3 scattered = float3(0.0f);

    // March each cube segment in turn, front-to-back, carrying transmittance and
    // in-scatter across cubes (overlap is fine: each cube contributes its slab).
    for (int s = 0; s < hitCount; ++s) {
        int ci = hitIdx[s];
        float3 c = cubes[ci].center.xyz;
        float3 h = cubes[ci].halfSize.xyz;
        float3 boxMin = c - h;
        float3 boxSize = h * 2.0f;
        float tn = hitNear[s];
        float tf = hitFar[s];
        int steps = min(int(ceil((tf - tn) / stepSize)), kViewSteps);

        for (int i = 0; i < steps; ++i) {
            float t = tn + (float(i) + 0.5f) * stepSize;
            if (t > tf) {
                break;
            }
            float3 p = ro + rd * t;

            float density = cloudDensity(p, u.time, coverageBias, shape, noise, boxMin, boxSize, ci, slabCount);
            if (density > 0.001f) {
                float opticalDepth = lightOpticalDepth(
                    p, sunDir, u.time, coverageBias, shape, noise, boxMin, boxSize, ci, slabCount);

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
        if (transmittance < 0.01f) {
            break;  // opaque: no farther cube can contribute
        }
    }

    float alpha = 1.0f - transmittance;
    return float4(scattered, alpha);
}
