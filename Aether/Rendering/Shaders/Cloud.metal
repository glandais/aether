#include <metal_stdlib>
using namespace metal;

// Multi-shell model (docs/SHELLS.md §6). The cloud's shape no longer comes from a
// finite painted AABB but from CONCENTRIC spherical SHELLS wrapping a small
// "planet" (the realtime_clouds reference). The camera sits on the surface; a
// ray that climbs (rd.y > 0) crosses each shell between intersectSphere(inner)
// and intersectSphere(outer). "Where there is cloud" is a painted directional
// coverage map (azimuth × elevation) sampled ONCE per shell per pixel — coverage
// is constant along a view ray. The vertical relief comes for free from the shell
// geometry (height_fraction) and the 3D noise (sampled in p, which varies along
// the ray).
//
// The shells are NESTED: an ascending ray crosses the lowest first, so marching
// them in order of increasing altitude is front-to-back with NO sorting. The
// transmittance and scattered radiance are SHARED across shells — a thin
// translucent cirrus lets the cumulus below show through. A shell is skipped
// (`continue`) where nothing is painted in the ray's direction or it is hidden,
// and the whole loop breaks once transmittance saturates (lower shells already
// opaque hide the higher ones).
//
// Lighting is unchanged from the cube path: multiple-scattering octaves, dual-lobe
// Henyey-Greenstein phase, powder, scene sun colour / sky ambient (resolved on the
// CPU). The light march is bounded to the current shell (self-shadowing only, no
// cross-shell shadowing, decision §11); it re-samples the coverage map per light
// step (§8 alternative) so edges of a painted stroke aren't over-shadowed.
// Temporal 2×2 amortization and the premultiplied composite are kept.

// One concentric shell (a painted layer). `inner`/`outer` are radii from the
// planet centre; `cloudType` drives the height gradient; `noiseScale` is in
// planet coordinates (~3e-4, NOT the cube `kNoiseScale`); `drift` advects the
// noise only. `coverageBias`/`opacity` are the layer's own (ex-weather).
// `layerSlice` is the shell's slice in the coverage atlas (its bake order, NOT
// its altitude rank); `visible` toggles the layer off without removing it.
struct Shell {
    float4 radii;       // x: inner, y: outer, z: cloudType, w: noiseScale
    float4 drift;       // xy: noise drift (planet coords / s), z: coverageBias, w: opacity
    uint   layerSlice;  // array slice of this shell in the coverage atlas
    uint   visible;     // 1 if the layer is shown, 0 to skip it
    uint   pad0;        // keep the struct 16-byte aligned (matches Swift `ShellGPU`)
    uint   pad1;
};

// Up to this many concentric shells (matches `CloudLayer.maxCount`).
constant uint kMaxShells = 4u;

struct CloudUniforms {
    float2 resolution;
    float  time;
    float  aspect;
    float4 sunDirection;    // xyz: normalized direction TOWARD the sun
    float4 camera;          // x: tan(vertical FOV / 2) — matches the photo's zoom
    float4 lightSun;        // xyz: sun colour × intensity (by altitude & exposure)
    float4 lightAmbient;    // xyz: sky ambient fill
    // Camera→world basis of the gaze (yaw + pitch), shared with the sky pass.
    // The view ray is reconstructed from these; at the identity basis it faces
    // North (-Z), matching the coverage stamp's `dir` convention.
    float4 camRight;
    float4 camUp;
    float4 camForward;
    // Concentric shells to march, sorted by increasing inner radius (lowest
    // first → front-to-back). `layerCount` bounds the loop; 0 = empty sky.
    Shell  shells[kMaxShells];
    uint   layerCount;
};

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

// Planet geometry (realtime_clouds reference, Sky.metal:295). The camera rests on
// the surface; cloud shells live a few hundred metres to a couple km above it.
constant float kPlanetRadius = 200000.0f;
// Extinction per metre of cloud. Planet-scale steps are hundreds of metres long
// (vs the cube path's ~0.1 world units), so the coefficient is correspondingly
// small: a few hundred metres of solid cloud reach opacity. Tuned by capture.
constant float kSigma = 0.0045f;
constant int   kLightSteps = 6;
// Light-march reach as a fraction of the shell thickness (bounded to this shell;
// self-shadowing only, decision §11). Scaled per layer by its thickness below.
constant float kLightReach = 0.6f;

// Noise: repeat (tileable, seamless). Coverage atlas uses a host sampler.
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

// MARK: - Shell geometry (ported from Sky.metal:511-535)

// Vertical density profile of a cloud type within its shell. Ported verbatim from
// the reference (mixGradients / densityHeightGradient, Sky.metal:511-525): a
// `cloudType` of 0 is a flat stratus, 1 a tall budding cumulus. Multiplied into
// the painted coverage so a shell reads thin at its floor/ceiling, full at its
// belly.
static inline float4 mixGradients(float cloudType) {
    const float4 STRATUS_GRADIENT = float4(0.02f, 0.05f, 0.09f, 0.11f);
    const float4 STRATOCUMULUS_GRADIENT = float4(0.02f, 0.2f, 0.48f, 0.625f);
    const float4 CUMULUS_GRADIENT = float4(0.01f, 0.0625f, 0.78f, 1.0f);
    float stratus = 1.0f - clamp(cloudType * 2.0f, 0.0f, 1.0f);
    float stratocumulus = 1.0f - abs(cloudType - 0.5f) * 2.0f;
    float cumulus = clamp(cloudType - 0.5f, 0.0f, 1.0f) * 2.0f;
    return STRATUS_GRADIENT * stratus
         + STRATOCUMULUS_GRADIENT * stratocumulus
         + CUMULUS_GRADIENT * cumulus;
}

static inline float densityHeightGradient(float heightFrac, float cloudType) {
    float4 g = mixGradients(cloudType);
    return smoothstep(g.x, g.y, heightFrac) - smoothstep(g.z, g.w, heightFrac);
}

// Ray/sphere intersection at radius r, returning the larger root scaled into a
// ray parameter t (ported from Sky.metal:527-535). `pos` is the eye in planet
// coordinates, `dir` the (unit) view ray.
static inline float intersectSphere(float3 pos, float3 dir, float r) {
    float a = dot(dir, dir);
    float b = 2.0f * dot(dir, pos);
    float c = dot(pos, pos) - r * r;
    float d = sqrt(b * b - 4.0f * a * c);
    float p = -b - d;
    float p2 = -b + d;
    return max(p, p2) / (2.0f * a);
}

// MARK: - Painted coverage

// Map a (unit) sky direction to the equirectangular upper-hemisphere coverage UV.
// Exact inverse of the stamp kernel's `dir` (BrushPaint.metal:161-164):
// uv.x = az/(2π)+0.5 with az = atan2(rd.x, -rd.z) (-Z = North → uv.x = 0.5),
// uv.y = asin(rd.y)/(π/2) (elevation over the upper hemisphere).
static inline float2 directionToEquirect(float3 rd) {
    float az = atan2(rd.x, -rd.z);
    float el = asin(clamp(rd.y, -1.0f, 1.0f));
    return float2(az / (2.0f * M_PI_F) + 0.5f, el / (M_PI_F * 0.5f));
}

// Painted density at planet point `p`. `cov` is the per-pixel coverage (constant
// along the ray), `g` the shell's height gradient, `noiseUVW` the drifting noise
// coordinate. Keeps Aether's remap chain (calibrated for painting) MULTIPLIED by
// the height gradient — deliberately NOT the reference's smoothstep(0.6,1.3)
// coverage window, which would erase the lower half of every stroke (docs/SHELLS.md
// note "shapeFrom" §6).
static inline float shapeDensity(float cov, float g, float3 noiseUVW,
                                 texture3d<float> noise) {
    float painted = saturate(cov);
    if (painted <= 0.001f) {
        return 0.0f;
    }
    float4 n = noise.sample(noiseSampler, noiseUVW);
    // The painted coverage shapes the Perlin-Worley base...
    float base = saturate(remap(n.r, 1.0f - painted, 1.0f, 0.0f, 1.0f));
    // ...and the Worley channels erode the detail.
    float detail = n.g * 0.625f + n.b * 0.25f + n.a * 0.125f;
    float density = remap(base, detail * 0.55f, 1.0f, 0.0f, 1.0f);
    // The vertical profile of this cloud type carves the shell's floor/ceiling.
    return saturate(density) * g;
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
                               texture3d<float> noise [[texture(1)]],
                               texture2d_array<float> coverage [[texture(3)]],
                               sampler coverageSampler [[sampler(0)]],
                               texture2d<float, access::read> history [[texture(2)]]) {
    // Temporal amortization: only the active 2×2 cell is raymarched this frame;
    // the others reuse the previous frame — valid only while the camera is still
    // (same pixel = same ray). While the gaze moves the ray under each pixel
    // changes, so reusing history would smear; raymarch all.
    uint2 px = uint2(in.position.xy);
    uint cellIndex = (px.y & 1) * 2 + (px.x & 1);
    if (temporal.cameraMoving == 0 && cellIndex != temporal.activeIndex) {
        return history.read(px);
    }

    if (u.layerCount == 0u) {
        return float4(0.0f);  // no painted shell this frame → empty sky
    }

    // Reconstruct the world-space view ray from the camera→world basis (mirror of
    // the sky pass). `in.ndc` is already clip-space (+Y up) from `cloud_vertex`.
    float2 ndc = in.ndc;
    float3 rd = normalize(
        ndc.x * u.camera.x * u.aspect * u.camRight.xyz +
        ndc.y * u.camera.x * u.camUp.xyz +
        u.camForward.xyz);

    // Below the horizon there is no shell to cross (the coverage map stops at
    // elevation 0). Match the reference: only ascending rays carry cloud.
    if (rd.y <= 0.0f) {
        return float4(0.0f);
    }

    // Coverage is constant along the ray: sample it once per shell at the ray's
    // direction (the direction is fixed along the ray).
    float2 covUV = directionToEquirect(rd);

    // Planet-space geometry. Camera on the surface, shells a few hundred m above.
    float3 camPos = float3(0.0f, kPlanetRadius, 0.0f);
    float3 sunDir = normalize(u.sunDirection.xyz);
    float3 sunColor = u.lightSun.xyz;
    float3 skyAmbient = u.lightAmbient.xyz;
    const int kScatterOctaves = 3;
    float cosTheta = dot(rd, sunDir);

    // Transmittance and scattered radiance are SHARED across the concentric
    // shells (docs/SHELLS.md §6): a thin cirrus above doesn't reset the cumulus
    // below, it composites over it front-to-back as the ray climbs.
    float transmittance = 1.0f;
    float3 scattered = float3(0.0f);

    // Front-to-back over the shells in increasing-altitude order (the lowest is
    // crossed first by an ascending ray); no per-pixel sorting.
    for (uint L = 0; L < u.layerCount && L < kMaxShells; ++L) {
        Shell sh = u.shells[L];
        if (sh.visible == 0u) {
            continue;  // layer toggled off
        }

        float cov = saturate(coverage.sample(coverageSampler, covUV, sh.layerSlice).r
                             + sh.drift.z);  // layer coverage bias
        if (cov <= 0.001f) {
            continue;  // nothing painted in this direction for this shell
        }

        float inner = sh.radii.x;
        float outer = sh.radii.y;
        float cloudType = sh.radii.z;
        float noiseScale = sh.radii.w;
        float2 drift = sh.drift.xy * u.time;
        float tdist = outer - inner;

        float3 start = camPos + rd * intersectSphere(camPos, rd, inner);
        float3 end   = camPos + rd * intersectSphere(camPos, rd, outer);

        // Unbounded step (docs/SHELLS.md §6, reference dmod Sky.metal:663-664). At
        // grazing angles the traversal reaches ~14× the shell thickness; dividing
        // it uniformly would give huge steps and banding right where the gaze
        // rests. The capped march covers only part of the traversal there —
        // acceptable, transmittance saturates first.
        int steps = int(mix(96.0f, 54.0f, rd.y));
        float dmod = smoothstep(0.0f, 1.0f, (length(end - start) / tdist) / 14.0f);
        float ss = mix(tdist, tdist * 4.0f, dmod) / float(steps);
        float3 p = start;
        float3 stepVec = rd * ss;

        // Per-layer opacity (drift.w). The weather density scale (step 6) is baked
        // into this opacity at scene creation, so there is no separate global
        // weather factor here — multiplying again would double-count the weather.
        float sigma = kSigma * sh.drift.w;
        // Light march reach in planet metres, bounded to this shell.
        float lightStep = tdist * kLightReach / float(kLightSteps);

        for (int i = 0; i < steps; ++i, p += stepVec) {
            float radius = length(p);
            float hf = (radius - inner) / tdist;          // height_fraction within shell
            if (hf < 0.0f || hf > 1.0f) {
                continue;
            }
            float g = densityHeightGradient(hf, cloudType);
            float3 noiseUVW = p * noiseScale + float3(drift.x, drift.y, drift.x);
            float density = shapeDensity(cov, g, noiseUVW, noise);
            if (density <= 0.001f) {
                continue;
            }

            // Self-shadowing: optical depth toward the sun, bounded to this shell
            // (decision §11, no cross-shell shadowing). The light ray re-samples
            // the coverage map at each step's own direction (§8 alternative):
            // without it, every point's light ray sees the full painted coverage
            // and the whole stroke reads pitch-black — the re-sample lets a light
            // ray that exits the painted silhouette brighten the stroke's edges.
            float opticalDepth = 0.0f;
            for (int j = 0; j < kLightSteps; ++j) {
                float3 q = p + sunDir * (float(j) + 0.5f) * lightStep;
                float qHf = (length(q) - inner) / tdist;
                if (qHf < 0.0f || qHf > 1.0f) {
                    continue;
                }
                float2 qUV = directionToEquirect(normalize(q));
                float qCov = saturate(coverage.sample(coverageSampler, qUV, sh.layerSlice).r
                                      + sh.drift.z);
                float qg = densityHeightGradient(qHf, cloudType);
                float3 qUVW = q * noiseScale + float3(drift.x, drift.y, drift.x);
                opticalDepth += shapeDensity(qCov, qg, qUVW, noise) * lightStep;
            }

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
            float extinction = density * sigma * ss;
            scattered += transmittance * luminance * extinction;
            transmittance *= exp(-extinction);

            if (transmittance < 0.01f) {
                break;  // opaque from here on within this shell
            }
        }

        if (transmittance < 0.01f) {
            break;  // opaque: higher shells are hidden
        }
    }

    float alpha = 1.0f - transmittance;
    return float4(scattered, alpha);
}
