#include <metal_stdlib>
using namespace metal;

// Background pass. Draws the dynamic atmospheric sky behind the clouds.
//
// `sky_background_fragment` reconstructs a world-space view ray per pixel and
// integrates Rayleigh + Mie single scattering toward the sun direction, so the
// sky above the horizon follows the real sun position (driven by the hour
// slider via AstroService). Below the horizon it keeps the curated landscape
// gradient (dimmed by the ground-light factor). `background_vertex` is the
// shared fullscreen triangle.
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
    float4 camera;             // x: tan(vertical FOV / 2); y: aspect (w/h); z: ground light; w: unused
    float4 camRight;           // xyz: camera→world basis (gaze yaw + pitch)
    float4 camUp;
    float4 camForward;         // xyz: gaze direction (-Z when upright/North)
    float4 sea0;               // x: enabled (0/1); y: level; z: wave height; w: choppy
    float4 sea1;               // x: frequency; y: speed; z: time; w: unused
    float4 seaBase;            // xyz: deep-water base colour
    float4 seaWater;           // xyz: water diffuse tint
    float4 moonDirection;      // xyz: world direction to the moon; w: night weight (0 day → 1 night)
    float4 moonGlint;          // xyz: moonlight colour (intensity included)
    float4 skyZenith;          // xyz: sky radiance at the zenith (CPU integral, linear HDR)
    float4 skyHorizon;         // xyz: sky radiance near the horizon (CPU integral, linear HDR)
    float4 discParams;         // x: sun angular radius; y: moon angular radius; z/w: unused
    float4 sunDiscColor;       // xyz: display-referred sun colour (0 below horizon); w: unused
    float4 moonDiscColor;      // xyz: cool-white moon colour, altitude-faded; w: unused
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

// --- Sea surface (heightmap raymarching) ------------------------------------
//
// Ported from "Seascape" by Alexander Alekseev aka TDM (2014),
// https://www.shadertoy.com/view/Ms2SD1 — CC BY-NC-SA 3.0. The original's flying
// camera, analytic sky and post gamma are dropped: the sea is traced along
// Aether's world-space view ray, lit by the real (AstroService) sun, and
// reflects Aether's own atmospheric sky (computeSkyRadiance) so the water stays
// coherent with the background above the horizon.

constant int SEA_NUM_STEPS = 6;
constant int SEA_ITER_GEOMETRY = 2;
constant int SEA_ITER_FRAGMENT = 4;
constant float2x2 SEA_OCTAVE_M = float2x2(1.6, 1.2, -1.2, 1.6);

struct SeaParams {
    float level;     // eye height above the mean surface (world units)
    float height;    // wave amplitude
    float choppy;    // crest sharpness
    float freq;      // spatial frequency
    float seaTime;   // animated phase (1 + time * speed)
    float3 base;     // deep-water colour
    float3 water;    // diffuse water tint
};

static float seaHash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

static float seaNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return -1.0 + 2.0 * mix(
        mix(seaHash(i + float2(0.0, 0.0)), seaHash(i + float2(1.0, 0.0)), u.x),
        mix(seaHash(i + float2(0.0, 1.0)), seaHash(i + float2(1.0, 1.0)), u.x), u.y);
}

static float seaOctave(float2 uv, float choppy) {
    uv += seaNoise(uv);
    float2 wv = 1.0 - abs(sin(uv));
    float2 swv = abs(cos(uv));
    wv = mix(wv, swv, wv);
    return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

// Signed height field: distance from the sample point to the wave surface
// (negative below, positive above). `iters` trades detail for speed (geometry
// pass during tracing vs. fragment pass for the normal).
static float seaMapHeight(float3 p, SeaParams sp, int iters) {
    float freq = sp.freq;
    float amp = sp.height;
    float choppy = sp.choppy;
    float2 uv = p.xz; uv.x *= 0.75;
    float d, h = 0.0;
    for (int i = 0; i < iters; ++i) {
        d  = seaOctave((uv + sp.seaTime) * freq, choppy);
        d += seaOctave((uv - sp.seaTime) * freq, choppy);
        h += d * amp;
        uv = SEA_OCTAVE_M * uv; freq *= 1.9; amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }
    return p.y - h;
}

static float3 seaNormal(float3 p, float eps, SeaParams sp) {
    float3 n;
    n.y = seaMapHeight(p, sp, SEA_ITER_FRAGMENT);
    n.x = seaMapHeight(float3(p.x + eps, p.y, p.z), sp, SEA_ITER_FRAGMENT) - n.y;
    n.z = seaMapHeight(float3(p.x, p.y, p.z + eps), sp, SEA_ITER_FRAGMENT) - n.y;
    n.y = eps;
    return normalize(n);
}

// False-position march toward the wave surface; converges fast for a height map.
static float seaTrace(float3 ori, float3 dir, SeaParams sp, thread float3 &p) {
    float tm = 0.0;
    float tx = 1000.0;
    float hx = seaMapHeight(ori + dir * tx, sp, SEA_ITER_GEOMETRY);
    if (hx > 0.0) { p = ori + dir * tx; return tx; }
    float hm = seaMapHeight(ori, sp, SEA_ITER_GEOMETRY);
    float tmid = 0.0;
    for (int i = 0; i < SEA_NUM_STEPS; ++i) {
        tmid = mix(tm, tx, hm / (hm - hx));
        p = ori + dir * tmid;
        float hmid = seaMapHeight(p, sp, SEA_ITER_GEOMETRY);
        if (hmid < 0.0) { tx = tmid; hx = hmid; }
        else { tm = tmid; hm = hmid; }
    }
    return tmid;
}

static float seaDiffuse(float3 n, float3 l, float p) {
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

static float seaSpecular(float3 n, float3 l, float3 e, float s) {
    float nrm = (s + 8.0) / (PI * 8.0);
    return pow(max(dot(reflect(e, n), l), 0.0), s) * nrm;
}

// Cheap reflected-sky colour for the water: a zenith↔horizon gradient built from
// two CPU-side atmospheric integrals (sky.skyZenith / sky.skyHorizon), tonemapped
// like the background. Avoids a full per-pixel sky integral inside the sea march
// (the dominant cost), while staying coherent with the sky above the horizon.
static float3 seaReflectedSky(float3 reflDir, constant SkyUniforms &sky) {
    const float t = clamp(reflDir.y, 0.0, 1.0);
    const float3 radiance = mix(sky.skyHorizon.xyz, sky.skyZenith.xyz, t);
    return 1.0 - exp(-radiance * sky.radii.w);
}

// Shade a traced water point. `eye` is the (normalised) world view ray, `sunDir`
// the world direction to the sun. Output is in display range (matches the
// tonemapped skyColor), so it blends seamlessly across the horizon.
static float3 seaShade(float3 p, float3 n, float3 eye, float3 sunDir,
                       SeaParams sp, constant SkyUniforms &sky) {
    float fresnel = clamp(1.0 - dot(n, -eye), 0.0, 1.0);
    fresnel = min(fresnel * fresnel * fresnel, 0.5);

    // Reflected sky (cheap gradient approximation, see seaReflectedSky).
    float3 reflDir = reflect(eye, n);
    reflDir.y = max(reflDir.y, 0.0);   // keep the reflection in the sky hemisphere
    float3 reflected = seaReflectedSky(reflDir, sky);

    // Day factor: sun above the horizon lights the water; below → night.
    float dayFactor = clamp(sunDir.y * 4.0 + 0.1, 0.0, 1.0);

    float3 refracted = sp.base + seaDiffuse(n, sunDir, 80.0) * sp.water * 0.12 * dayFactor;
    float3 color = mix(refracted, reflected, fresnel);

    // Near-field crest tint, faded with distance (eye at local origin). Clamped
    // to the crests only: the raw (p.y - height) goes negative in troughs, which
    // multiplied by the water tint produced black streaks at this low eye height.
    float atten = max(1.0 - dot(p, p) * 0.001, 0.0);
    color += sp.water * max(p.y - sp.height, 0.0) * 0.18 * atten * dayFactor;

    // Sun glint (specular), daytime only.
    color += seaSpecular(n, sunDir, eye, 60.0) * dayFactor;

    // Dim the sun/sky-lit appearance at night (ground-light factor), so the
    // constant base water doesn't stay bright under a dark sky.
    color *= sky.camera.z;

    // Moonlight: a cool moonglade (specular streak broadened by the waves) plus
    // a faint sheen on water facing the moon. Night-gated and scaled by the
    // moonlight colour, so it survives the ground-light dimming above and only
    // appears once the moon is up at night. A broad lobe (low exponent) spreads
    // the glade into a soft column instead of pinpoint sparkles, and the streak
    // intensity is soft-knee compressed so bright crests roll off toward the
    // cool moon colour rather than clipping to harsh white.
    const float3 moonDir = normalize(sky.moonDirection.xyz);
    const float nightW = sky.moonDirection.w;
    if (sky.moonDirection.y > 0.0 && nightW > 0.0) {
        const float3 moonColor = sky.moonGlint.xyz;
        const float glade = seaSpecular(n, moonDir, eye, 90.0);
        const float sheen = seaDiffuse(n, moonDir, 40.0) * fresnel * 0.18;
        float intensity = (glade * 0.3 + sheen) * nightW;
        intensity = intensity / (1.0 + intensity);   // soft knee: rolls off to 1
        color += moonColor * intensity;
    }

    return color;
}

// --- Sun & moon discs -------------------------------------------------------

// Bilinear value noise on a hash lattice. Used only for faint lunar surface
// mottling, so quality is uncritical; cheap and tile-free is enough.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    const float2 i = floor(p);
    const float2 f = fract(p);
    const float2 u = f * f * (3.0 - 2.0 * f);
    const float a = hash21(i);
    const float b = hash21(i + float2(1.0, 0.0));
    const float c = hash21(i + float2(0.0, 1.0));
    const float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Sun: a bright core with a soft bloom halo. `sunDiscColor` is supplied by the
// CPU as the atmospheric transmittance toward the sun, hence warm/reddened when
// low and exactly zero below the horizon — so the disc fades out on its own.
static float3 sunDisc(float3 rayDir, float3 sunDir, constant SkyUniforms &sky) {
    const float radius = sky.discParams.x;
    const float cosToSun = dot(rayDir, sunDir);
    const float cosR = cos(radius);
    const float limb = radius * 0.35;          // soft edge ~1/3 of the radius
    const float core = smoothstep(cosR - limb * (1.0 - cosR), cosR, cosToSun);
    const float glow = pow(max(cosToSun, 0.0), 2200.0) * 0.5;  // gentle bloom
    return sky.sunDiscColor.xyz * (core + glow);
}

// Moon: a phased disc whose lit/dark split and crescent orientation come purely
// from the apparent sun and moon directions (mirrors `MoonPhase` on the CPU).
// Adds faint earthshine on the dark side and subtle surface mottling.
static float3 moonDisc(float3 rayDir, float3 sunDir, float3 moonDir,
                       constant SkyUniforms &sky) {
    const float radius = sky.discParams.y;
    const float cosD = dot(rayDir, moonDir);
    if (cosD < cos(radius * 1.6)) {            // outside the disc (+ margin)
        return float3(0.0);
    }

    // Bright-limb direction: sun projected into the moon's disc plane.
    const float3 proj = sunDir - dot(sunDir, moonDir) * moonDir;
    const float projLen = length(proj);
    const float3 brightDir = (projLen > 1e-4)
        ? proj / projLen
        : normalize(cross(moonDir, float3(0.0, 1.0, 0.0)));
    const float3 tangent = cross(moonDir, brightDir);

    // Map the ray's angular offset from the moon centre into disc coords.
    const float3 off = rayDir - cosD * moonDir;
    const float ang = acos(clamp(cosD, -1.0, 1.0));
    const float r = ang / radius;              // 0 centre → 1 limb (perfectly round)
    const float2 raw = float2(dot(off, brightDir), dot(off, tangent));
    const float2 dir2 = (length(raw) > 1e-6) ? normalize(raw) : float2(0.0);
    const float a = r * dir2.x;
    const float b = r * dir2.y;

    // Visible-hemisphere surface normal (`-moonDir` faces the viewer).
    const float h = sqrt(max(0.0, 1.0 - a * a - b * b));
    const float3 normal = a * brightDir + b * tangent - h * moonDir;

    const float lit = smoothstep(-0.05, 0.05, dot(normal, sunDir));
    const float mott = 1.0 + (valueNoise(float2(a, b) * 6.0) - 0.5) * 0.12;
    const float earthshine = 0.02 * (1.0 - lit) *
        smoothstep(0.0, 0.5, dot(sunDir, -moonDir) * 0.5 + 0.5);
    const float edge = 1.0 - smoothstep(1.0 - fwidth(r) - radius * 0.3, 1.0, r);

    return sky.moonDiscColor.xyz * (lit * mott + earthshine) * edge;
}

fragment float4 sky_background_fragment(BackgroundInOut in [[stage_in]],
                                        constant SkyUniforms &sky [[buffer(0)]],
                                        texture2d<float> landscape [[texture(0)]],
                                        sampler smp [[sampler(0)]]) {
    // Reconstruct the world-space view ray. Camera convention (shared with
    // Cloud.metal): -Z = North, +X = East, +Y = up. The gaze can be rotated
    // (yaw + pitch) via the camera→world basis passed from the Renderer; at the
    // identity basis (right=+X, up=+Y, forward=-Z) this equals the fixed
    // North-facing ray. The cloud volume is world-fixed and uses the same basis,
    // so sky, sun and clouds all follow the gaze together.
    const float tanHalfFov = sky.camera.x;
    const float aspect = sky.camera.y;
    const float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    const float3 rayDir = normalize(
        ndc.x * tanHalfFov * aspect * sky.camRight.xyz +
        ndc.y * tanHalfFov * sky.camUp.xyz +
        sky.camForward.xyz);

    // Eye at the surface; planet centered at the origin so +Y is radial up.
    const float3 origin = float3(0.0, sky.radii.x + sky.radii.z, 0.0);
    const float3 sunDir = normalize(sky.sunDirection.xyz);

    // Tonemap the HDR sky to display range (simple exponential exposure). Skip
    // the (costly) integral well below the horizon, where the sky is fully
    // occluded by the sea/ground and only its faint cross-fade near the horizon
    // line would ever use it.
    const float exposure = sky.radii.w;
    float3 skyColor = float3(0.0);
    if (rayDir.y > -0.05) {
        const float3 radiance = computeSkyRadiance(origin, rayDir, sunDir, sky);
        skyColor = 1.0 - exp(-radiance * exposure);
    }

    const float3 discMoonDir = normalize(sky.moonDirection.xyz);

    // Moonlight in the sky. The moon, like the sun, should glow and tint the sky —
    // but a full atmospheric integral toward the moon adds a warm grazing-horizon
    // band that reads as a false dawn at night. Instead, an analytic cool halo: a
    // soft forward lobe around the disc (the *glow*) plus a faint overall lift so
    // the night sky picks up the moonlight rather than staying pure black (its
    // *incidence on the sky colour*). Tinted by the moonlight colour (cool, scaled
    // by phase + altitude via moonGlint), night-gated, and skipped when the moon is
    // down — cheap and free of the false-dawn band.
    const float nightW = sky.moonDirection.w;
    if (nightW > 0.0 && discMoonDir.y > -0.05) {
        const float cosToMoon = max(dot(rayDir, discMoonDir), 0.0);
        const float halo = pow(cosToMoon, 250.0) * 0.6 + pow(cosToMoon, 8.0) * 0.05;
        const float lift = 0.015 * smoothstep(0.0, 0.3, discMoonDir.y);
        skyColor += sky.moonGlint.xyz * (halo + lift) * nightW;
    }

    // Sun & moon discs, added as display-referred colours on top of the tonemapped
    // sky (a low-radiance moon would be crushed if injected before the exposure
    // curve). The ground/sea mix below clips any disc that crosses the horizon, and
    // the later cloud composite pass occludes them where clouds are painted.
    skyColor += sunDisc(rayDir, sunDir, sky);
    skyColor += moonDisc(rayDir, sunDir, discMoonDir, sky);

    // Below the horizon: either a raymarched sea (when the curated landscape
    // enables one) or a single meaningful ground tone. Both are anchored to the
    // view angle (rayDir.y), not the screen, so pitching the gaze can't expose
    // the baked vertical gradient, and both are dimmed by the ground-light
    // factor so they darken at night with the sky.
    float3 below;
    if (sky.sea0.x > 0.5 && rayDir.y < 0.06) {
        // Local frame: eye at origin lifted by `level`, mean surface near y = 0,
        // so descending rays (rayDir.y < 0) intersect the waves. The view ray is
        // already world-space, so the swell stays world-locked as the gaze pans.
        SeaParams sp;
        sp.level = sky.sea0.y;
        sp.height = sky.sea0.z;
        sp.choppy = sky.sea0.w;
        sp.freq = sky.sea1.x;
        sp.seaTime = 1.0 + sky.sea1.z * sky.sea1.y;
        sp.base = sky.seaBase.xyz;
        sp.water = sky.seaWater.xyz;

        const float3 ro = float3(0.0, sp.level, 0.0);
        float3 p;
        seaTrace(ro, rayDir, sp, p);
        const float eps = dot(p, p) * (0.1 / max(sky.camera.x, 1e-3)) * 1e-3;
        const float3 n = seaNormal(p, max(eps, 1e-3), sp);
        const float3 seaCol = seaShade(p, n, rayDir, sunDir, sp, sky);

        // Dissolve distant water into the atmospheric horizon. Near the horizon
        // the height trace hits very far away where the march no longer converges
        // and the wave detail aliases into spikes; fading toward the flat-water
        // horizon reflection there yields a clean, hazy horizon (free — same
        // gradient as the reflected sky, with the surface flat = normal up).
        const float dist = length(p - ro);
        const float3 horizon = seaReflectedSky(float3(0.0, 0.03, 0.0), sky);
        below = mix(seaCol, horizon, smoothstep(150.0, 800.0, dist));
    } else {
        const float3 groundColor = landscape.sample(smp, float2(0.5, 1.0)).rgb;
        const float belowness = clamp(-rayDir.y * 1.5, 0.0, 1.0);
        below = groundColor * mix(1.0, 0.55, belowness) * sky.camera.z;
    }
    const float blend = smoothstep(-0.01, 0.04, rayDir.y);

    return float4(mix(below, skyColor, blend), 1.0);
}
