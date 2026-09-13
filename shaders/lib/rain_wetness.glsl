/* MakeUp - rain_wetness.glsl
Rain-driven surface wetness (darkened, glossy ground + puddles) with
screen-space reflections on wet terrain.

This runs as a full-screen composite-stage effect, after all opaque and
translucent geometry has already been drawn into colortex1. Because of
that, it has no dedicated normal G-buffer to read: view-space position
and normal are reconstructed directly from the depth buffer instead.

Javier Garduño's original SSR raymarch (see /lib/water.glsl) can't be
reused as-is for this pass: it is written against a texture-space normal
map with a full tangent/binormal basis built for wavy water, evaluated
while translucents are being drawn (with gaux1 as the "already-drawn
opaque scene" source). Here we instead read colortex1 - the composited
result of the WHOLE scene so far - so a plain geometric reflection
vector from the reconstructed depth normal is enough for a flat puddle.
*/

// Interleaved-gradient-noise style hash. Self-contained on purpose so
// this file has no dependency on /lib/dither.glsl (which may or may
// not already be included depending on which VOL_LIGHT path is active).
float wetnessDither(vec2 coord) {
    return fract(52.9829189 * fract(dot(coord, vec2(0.06711056, 0.00583715))));
}

vec3 wetViewPos(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 view = gbufferProjectionInverse * clip;
    return view.xyz / view.w;
}

// Best-neighbour depth-buffer normal reconstruction: for each axis, pick
// whichever side has the smaller depth jump from the center sample, so
// the estimated normal doesn't get dragged across geometry edges.
vec3 wetNormal(vec2 uv, vec3 viewPos, float depth) {
    vec2 texel = vec2(pixelSizeX, pixelSizeY);

    float depthX1 = texture2D(depthtex0, uv + vec2(texel.x, 0.0)).r;
    float depthX2 = texture2D(depthtex0, uv - vec2(texel.x, 0.0)).r;
    float depthY1 = texture2D(depthtex0, uv + vec2(0.0, texel.y)).r;
    float depthY2 = texture2D(depthtex0, uv - vec2(0.0, texel.y)).r;

    vec3 posX1 = wetViewPos(uv + vec2(texel.x, 0.0), depthX1);
    vec3 posX2 = wetViewPos(uv - vec2(texel.x, 0.0), depthX2);
    vec3 posY1 = wetViewPos(uv + vec2(0.0, texel.y), depthY1);
    vec3 posY2 = wetViewPos(uv - vec2(0.0, texel.y), depthY2);

    vec3 dx = (abs(depthX1 - depth) < abs(depthX2 - depth)) ? (posX1 - viewPos) : (viewPos - posX2);
    vec3 dy = (abs(depthY1 - depth) < abs(depthY2 - depth)) ? (posY1 - viewPos) : (viewPos - posY2);

    return normalize(cross(dx, dy));
}

// Irregular puddle mask: only near-flat, upward-facing ground can hold
// water, and puddles grow to cover more ground as rainStrength climbs.
float puddleMask(vec3 viewPos, vec3 viewNormal) {
    vec3 upVectorView = normalize((gbufferModelView * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
    float upFacing = clamp(dot(viewNormal, upVectorView), 0.0, 1.0);
    upFacing = pow(upFacing, 4.0);  // Steep falloff: slopes/walls stay dry

    if (upFacing <= 0.001) return 0.0;

    vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;

    // Two octaves of the existing noise texture (same trick /lib/water.glsl
    // uses for wave shapes) so puddle edges don't look like a uniform sheet.
    vec2 n1 = texture2D(noisetex, worldPos.xz * WETNESS_PUDDLE_SCALE).rg;
    vec2 n2 = texture2D(noisetex, worldPos.xz * WETNESS_PUDDLE_SCALE * 2.37 + 13.0).rg;
    float puddleNoise = (n1.r + n2.r) * 0.5;

    float threshold = mix(1.05, 0.35, rainStrength);  // Drops as rain intensifies
    float puddle = smoothstep(threshold - 0.12, threshold, puddleNoise);

    return puddle * upFacing * rainStrength;
}

// Fixed-count raymarch through colortex1/depthtex0. Deliberately simpler
// than fastRaymarch() in /lib/water.glsl (no binary refinement step) -
// puddle reflections are subtle and don't need the same accuracy budget
// water gets, and this keeps the composite pass cheap.
vec3 wetnessRaymarch(vec3 viewPos, vec3 reflected, float dither) {
    vec3 rayStep = reflected * (0.5 + dither);
    vec3 marchPos = viewPos;
    vec3 screenPos;

    for (int i = 0; i < WETNESS_RAYMARCH_STEPS; i++) {
        marchPos += rayStep;
        screenPos = camera_to_screen(marchPos);

        if (screenPos.x < 0.0 || screenPos.x > 1.0 ||
            screenPos.y < 0.0 || screenPos.y > 1.0 ||
            screenPos.z < 0.0 || screenPos.z > 1.0) {
            return vec3(-1.0);  // Left the screen: no hit, fall back to sky/ambient
        }

        float sampledDepth = texture2D(depthtex0, screenPos.xy).r;
        if (sampledDepth < screenPos.z) {
            return screenPos;  // Something is between the camera and the ray here
        }

        rayStep *= 1.4;  // Growing step: keeps distant reflections cheap
    }

    return vec3(-1.0);
}

void applyRainWetness(inout vec3 color, vec2 uv, float depth, float dither) {
    if (depth > 0.9999 || rainStrength <= 0.001) return;  // Sky, or not raining

    vec3 viewPos = wetViewPos(uv, depth);
    vec3 viewNormal = wetNormal(uv, viewPos, depth);
    float wetness = puddleMask(viewPos, viewNormal);

    if (wetness <= 0.001) return;

    // Wet ground reads darker and glossier than dry ground.
    color *= mix(1.0, 0.82, wetness);

    vec3 reflected = reflect(normalize(viewPos), viewNormal);
    vec3 hit = wetnessRaymarch(viewPos, reflected, dither);

    vec3 reflectionColor = color;
    float reflectionVisibility = 0.0;

    if (hit.x >= 0.0) {
        reflectionColor = texture2D(colortex1, hit.xy).rgb;
        // Fade near the screen border so reflections don't pop in/out.
        float edgeFade = clamp((1.0 - max(abs(hit.x - 0.5), abs(hit.y - 0.5)) * 2.0) * 4.0, 0.0, 1.0);
        reflectionVisibility = edgeFade;
    }

    float fresnel = pow(1.0 - clamp(dot(-normalize(viewPos), viewNormal), 0.0, 1.0), 3.0);
    float finalReflectivity =
        wetness * WETNESS_REFLECTION_STRENGTH * mix(0.4, 1.0, fresnel) * reflectionVisibility;

    color = mix(color, reflectionColor, finalReflectivity);
}
