#include <metal_stdlib>
using namespace metal;

// Background pass. Draws the scene behind the volumetric clouds.
//
// `background_fragment` is the original placeholder: it samples the curated
// landscape gradient fullscreen. It is still the one wired in `Renderer`.
//
// `sky_background_fragment` is the dynamic-atmosphere sketch: it reconstructs a
// world-space view ray per pixel and integrates Rayleigh + Mie single
// scattering toward the sun direction, so the sky above the horizon follows the
// real sun position (driven by the hour slider via AstroService). Below the
// horizon it keeps the landscape gradient. Switching the background pipeline to
// this entry point + feeding `SkyUniforms` is the remaining Renderer wiring
// step (see CLAUDE.md "Fond de ciel dynamique").
//
// Reference: CesiumJS AtmosphereCommon.glsl (computeScattering), Nishita 1993,
// Hillaire 2020. See BIBLIO.md.

constant float PI = 3.14159265358979;

struct BackgroundInOut {
    float4 position [[position]];
    float2 uv;
};

// Atmosphere uniforms. The memory layout must match the `SkyUniforms` Swift
// struct in `Renderer` (float4 packing, same field order — like CloudUniforms).
struct SkyUniforms {
    float4 sunDirection;       // xyz: world direction TO the sun; w: unused
    float4 rayleighScattering; // xyz: Rayleigh coeff (m⁻¹); w: Mie coeff (m⁻¹)
    float4 scaleHeights;       // x: Rayleigh H; y: Mie H; z: Mie g; w: sun intensity
    float4 radii;              // x: planet radius; y: atmosphere radius; z: eye height; w: exposure
    float4 camera;             // x: tan(vertical FOV / 2); y: aspect (w/h); zw: unused
};

// Fullscreen triangle generated from the vertex id — no vertex buffer needed.
// UV is flipped on Y so the texture (top-left origin) appears upright.
vertex BackgroundInOut background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 p = positions[vertexID];
    BackgroundInOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
    return out;
}

fragment float4 background_fragment(BackgroundInOut in [[stage_in]],
                                    texture2d<float> landscape [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
    return landscape.sample(smp, in.uv);
}

// --- Dynamic atmosphere -----------------------------------------------------

// Ray / sphere intersection, sphere centered at the origin (planet center).
// Returns (near, far) distances along `dir`; far < near means no hit.
static float2 raySphere(float3 origin, float3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float d = b * b - c;
    if (d < 0.0) {
        return float2(1.0, -1.0); // no intersection
    }
    d = sqrt(d);
    return float2(-b - d, -b + d);
}

// Single-scattering in-scattered radiance along a view ray that starts at the
// eye and exits through the top of the atmosphere (or hits the ground).
// Mirrors the structure of CesiumJS computeScattering(): a primary march
// accumulating optical depth, with an inner light-march toward the sun for the
// transmittance of the incoming sunlight at each sample.
static float3 computeSkyRadiance(float3 origin, float3 rayDir, float3 sunDir,
                                 constant SkyUniforms &sky) {
    const float rayleighH = sky.scaleHeights.x;
    const float mieH = sky.scaleHeights.y;
    const float g = sky.scaleHeights.z;
    const float3 betaR = sky.rayleighScattering.xyz;
    const float betaM = sky.rayleighScattering.w;
    const float planetRadius = sky.radii.x;
    const float atmosphereRadius = sky.radii.y;

    // March length: to the top of the atmosphere, clamped to the ground if the
    // ray dips below the horizon and hits the planet.
    float2 atmHit = raySphere(origin, rayDir, atmosphereRadius);
    if (atmHit.y < 0.0) {
        return float3(0.0); // ray never enters the atmosphere
    }
    float rayLength = atmHit.y;
    float2 groundHit = raySphere(origin, rayDir, planetRadius);
    if (groundHit.x > 0.0) {
        rayLength = min(rayLength, groundHit.x);
    }

    const int PRIMARY_STEPS = 16;
    const int LIGHT_STEPS = 8;
    const float stepSize = rayLength / float(PRIMARY_STEPS);

    // Phase functions, evaluated once: depend only on the view/sun angle.
    const float mu = dot(rayDir, sunDir);
    const float phaseR = (3.0 / (16.0 * PI)) * (1.0 + mu * mu);
    const float gg = g * g;
    const float phaseM = (3.0 / (8.0 * PI)) * ((1.0 - gg) * (1.0 + mu * mu)) /
                         ((2.0 + gg) * pow(1.0 + gg - 2.0 * g * mu, 1.5));

    float3 rayleighSum = float3(0.0);
    float3 mieSum = float3(0.0);
    float opticalDepthR = 0.0;
    float opticalDepthM = 0.0;
    float t = 0.0;

    for (int i = 0; i < PRIMARY_STEPS; ++i) {
        const float3 samplePos = origin + rayDir * (t + 0.5 * stepSize);
        const float height = length(samplePos) - planetRadius;
        const float densityR = exp(-height / rayleighH) * stepSize;
        const float densityM = exp(-height / mieH) * stepSize;
        opticalDepthR += densityR;
        opticalDepthM += densityM;

        // Light march toward the sun: optical depth of incoming sunlight.
        const float2 lightHit = raySphere(samplePos, sunDir, atmosphereRadius);
        const float lightStep = lightHit.y / float(LIGHT_STEPS);
        float lightOpticalR = 0.0;
        float lightOpticalM = 0.0;
        float lt = 0.0;
        bool occluded = false;
        for (int j = 0; j < LIGHT_STEPS; ++j) {
            const float3 lightPos = samplePos + sunDir * (lt + 0.5 * lightStep);
            const float lightHeight = length(lightPos) - planetRadius;
            if (lightHeight < 0.0) { // sun below the local horizon (in shadow)
                occluded = true;
                break;
            }
            lightOpticalR += exp(-lightHeight / rayleighH) * lightStep;
            lightOpticalM += exp(-lightHeight / mieH) * lightStep;
            lt += lightStep;
        }
        if (occluded) {
            t += stepSize;
            continue;
        }

        // Transmittance = exp(-extinction). Mie extinction ≈ 1.1 × scattering.
        const float3 tau = betaR * (opticalDepthR + lightOpticalR) +
                           betaM * 1.1 * (opticalDepthM + lightOpticalM);
        const float3 attenuation = exp(-tau);
        rayleighSum += densityR * attenuation;
        mieSum += densityM * attenuation;
        t += stepSize;
    }

    return sky.scaleHeights.w *
           (rayleighSum * betaR * phaseR + mieSum * betaM * phaseM);
}

fragment float4 sky_background_fragment(BackgroundInOut in [[stage_in]],
                                        constant SkyUniforms &sky [[buffer(0)]],
                                        texture2d<float> landscape [[texture(0)]],
                                        sampler smp [[sampler(0)]]) {
    // Reconstruct the world-space view ray. Camera convention (shared with
    // Cloud.metal): faces North, -Z = North, +X = East, +Y = up. The curated
    // camera is upright (no attitude tilt since photo import was removed), so
    // camera space ≈ world space and local "up" is +Y.
    const float tanHalfFov = sky.camera.x;
    const float aspect = sky.camera.y;
    const float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    const float3 rayDir = normalize(
        float3(ndc.x * tanHalfFov * aspect, ndc.y * tanHalfFov, -1.0));

    // Eye at the surface; planet centered at the origin so +Y is radial up.
    const float3 origin = float3(0.0, sky.radii.x + sky.radii.z, 0.0);
    const float3 sunDir = normalize(sky.sunDirection.xyz);

    const float3 radiance = computeSkyRadiance(origin, rayDir, sunDir, sky);

    // Tonemap the HDR sky to display range (simple exponential exposure).
    const float exposure = sky.radii.w;
    const float3 skyColor = 1.0 - exp(-radiance * exposure);

    // Keep the landscape gradient below the horizon; cross-fade across it.
    const float3 ground = landscape.sample(smp, in.uv).rgb;
    const float blend = smoothstep(-0.01, 0.04, rayDir.y);

    return float4(mix(ground, skyColor, blend), 1.0);
}
