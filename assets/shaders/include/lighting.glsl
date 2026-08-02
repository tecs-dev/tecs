// The grid lights are binned into, shared by the pass that fills it and the
// pass that reads it.
//
// A fragment consults the lights whose tile it is in rather than every light
// in the scene, which is what makes many lights affordable: a light's cost
// becomes proportional to what it covers instead of to how many pixels exist.
//
// World space, not screen space and not normalized device coordinates. The
// grid covers the rectangle the camera can see, measured in world units, so a
// light's position and its radius are both already in the space the tiles are
// measured in and the zoom enters once, as the half extent of that rectangle.
// Binning in device coordinates would mean projecting a radius, which is not
// a length under a projection and has to be recovered per light.
//
// The grid is a fixed count rather than a fixed tile size in pixels, so its
// two buffers are allocated once and never resized. A buffer that grew with
// the window would have to be replaced while a frame in flight was still
// reading the old one, and the granularity a resolution-independent grid gives
// up is granularity binning barely uses: what a fragment needs is a short list,
// not the shortest one.

// Tiles the view is divided into on each axis. `lightlayout.TILES` in
// src/tecs/gpu/lightlayout.tl is the same number, and the pair only works
// while they agree.
const int LIGHT_TILES = 32;

// Lights one tile holds. `lightlayout.TILE_SLOTS` is the same number. A tile
// reached by more than this keeps the ones earliest in the light buffer and
// drops the rest, which is a deterministic choice rather than whichever
// arrived first.
const int LIGHT_TILE_SLOTS = 64;

// Which tile a world position falls in.
//
// `bounds` is the world rectangle the grid covers, as minimum xy then maximum
// xy. Clamped rather than tested, because a fragment at the very edge of the
// view can land a rounding error outside the rectangle its own camera
// produced, and the nearest tile is the right answer there.
int lightTileOf(vec2 world, vec4 bounds) {
    vec2 span = max(bounds.zw - bounds.xy, vec2(1e-6));
    vec2 across = (world - bounds.xy) / span;
    ivec2 cell = clamp(ivec2(floor(across * float(LIGHT_TILES))),
                       ivec2(0), ivec2(LIGHT_TILES - 1));
    return cell.y * LIGHT_TILES + cell.x;
}

// Which fixed tile a target fragment occupies. `viewport` carries width and
// height in xy and its framebuffer origin in zw, so split-screen views index
// the same local 32 by 32 grid as a full-frame view.
int screenLightTileOf(vec2 fragment, vec4 viewport) {
    vec2 size = max(viewport.xy, vec2(1.0));
    vec2 across = (fragment - viewport.zw) / size;
    ivec2 cell = clamp(ivec2(floor(across * float(LIGHT_TILES))),
                       ivec2(0), ivec2(LIGHT_TILES - 1));
    return cell.y * LIGHT_TILES + cell.x;
}

#include "meshlight.glsl"

#ifdef MESH_LOCAL_SHADOWS
int meshLocalShadowFace(vec3 fromLight) {
    vec3 magnitude = abs(fromLight);
    if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
        return fromLight.x >= 0.0 ? 0 : 1;
    }
    if (magnitude.y >= magnitude.z) {
        return fromLight.y >= 0.0 ? 2 : 3;
    }
    return fromLight.z >= 0.0 ? 4 : 5;
}

mat4 meshLocalShadowMatrix(int index) {
    int at = index * 16;
    return mat4(
        meshLocalShadowMatrices.value[at], meshLocalShadowMatrices.value[at + 1],
        meshLocalShadowMatrices.value[at + 2], meshLocalShadowMatrices.value[at + 3],
        meshLocalShadowMatrices.value[at + 4], meshLocalShadowMatrices.value[at + 5],
        meshLocalShadowMatrices.value[at + 6], meshLocalShadowMatrices.value[at + 7],
        meshLocalShadowMatrices.value[at + 8], meshLocalShadowMatrices.value[at + 9],
        meshLocalShadowMatrices.value[at + 10], meshLocalShadowMatrices.value[at + 11],
        meshLocalShadowMatrices.value[at + 12], meshLocalShadowMatrices.value[at + 13],
        meshLocalShadowMatrices.value[at + 14], meshLocalShadowMatrices.value[at + 15]);
}

float meshLocalShadowVisibility(
    MeshLight light, vec3 world, vec3 normal, float bias, float softness
) {
    int slot = int(light.coneType.z) - 1;
    if (slot < 0) { return 1.0; }

    vec3 fromLight = world - light.positionRadius.xyz;
    int face = light.coneType.y < 0.5 ? meshLocalShadowFace(fromLight) : 0;
    vec4 projected = meshLocalShadowMatrix(slot * 6 + face) * vec4(world, 1.0);
    vec3 shadow = projected.xyz / projected.w;
    vec2 localUV = shadow.xy * 0.5 + 0.5;
    if (shadow.z < 0.0 || shadow.z > 1.0
            || any(lessThan(localUV, vec2(0.0))) || any(greaterThan(localUV, vec2(1.0)))) {
        return 1.0;
    }

    ivec2 atlasPixels = textureSize(meshLocalShadowAtlas, 0);
    float cellPixels = float(atlasPixels.x) / 6.0;
    vec2 cellOrigin = vec2(float(face) * cellPixels, float(slot) * cellPixels);
    vec2 atlasUV = (cellOrigin + localUV * cellPixels) / vec2(atlasPixels);
    vec2 texel = 1.0 / vec2(atlasPixels);
    vec2 cellMin = (cellOrigin + vec2(0.5)) / vec2(atlasPixels);
    vec2 cellMax = (cellOrigin + vec2(cellPixels - 0.5)) / vec2(atlasPixels);
    vec3 toLight = normalize(-fromLight);
    float receiver = shadow.z - bias * (1.0 + 1.0 - max(dot(normalize(normal), toLight), 0.0));
    if (softness <= 0.0) {
        return receiver <= texture(meshLocalShadowAtlas, atlasUV).r ? 1.0 : 0.0;
    }

    float visible = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 sampleUV = clamp(atlasUV + vec2(x, y) * texel * softness, cellMin, cellMax);
            visible += receiver <= texture(meshLocalShadowAtlas, sampleUV).r ? 1.0 : 0.0;
        }
    }
    return visible / 9.0;
}
#endif

// Shared metallic-roughness direct-light term. The distribution is
// Trowbridge-Reitz GGX, visibility is Smith with Schlick-GGX, and Fresnel is
// Schlick's approximation. Keeping this here makes deferred opaque surfaces
// and forward blended meshes consume the same material contract.
const float PBR_PI = 3.14159265358979323846;

float pbrDistributionGGX(vec3 normal, vec3 halfway, float roughness) {
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float nDotH = max(dot(normal, halfway), 0.0);
    float nDotH2 = nDotH * nDotH;
    float denominator = nDotH2 * (alpha2 - 1.0) + 1.0;
    return alpha2 / max(PBR_PI * denominator * denominator, 1e-6);
}

float pbrGeometrySchlickGGX(float nDotDirection, float roughness) {
    float r = roughness + 1.0;
    float k = r * r * 0.125;
    return nDotDirection / max(nDotDirection * (1.0 - k) + k, 1e-6);
}

float pbrGeometrySmith(vec3 normal, vec3 viewDirection, vec3 lightDirection, float roughness) {
    return pbrGeometrySchlickGGX(max(dot(normal, viewDirection), 0.0), roughness)
         * pbrGeometrySchlickGGX(max(dot(normal, lightDirection), 0.0), roughness);
}

vec3 pbrFresnelSchlick(float cosine, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cosine, 0.0, 1.0), 5.0);
}

vec3 cookTorrance(
    vec3 albedo,
    vec3 normal,
    vec3 viewDirection,
    vec3 lightDirection,
    vec3 radiance,
    float roughness,
    float metallic
) {
    roughness = clamp(roughness, 0.045, 1.0);
    metallic = clamp(metallic, 0.0, 1.0);
    float nDotL = max(dot(normal, lightDirection), 0.0);
    float nDotV = max(dot(normal, viewDirection), 0.0);
    if (nDotL <= 0.0 || nDotV <= 0.0) {
        return vec3(0.0);
    }

    vec3 halfway = normalize(viewDirection + lightDirection);
    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    vec3 fresnel = pbrFresnelSchlick(max(dot(halfway, viewDirection), 0.0), f0);
    float distribution = pbrDistributionGGX(normal, halfway, roughness);
    float geometry = pbrGeometrySmith(normal, viewDirection, lightDirection, roughness);
    vec3 specular = distribution * geometry * fresnel / max(4.0 * nDotV * nDotL, 1e-5);
    vec3 diffuseWeight = (vec3(1.0) - fresnel) * (1.0 - metallic);
    return (diffuseWeight * albedo / PBR_PI + specular) * radiance * nDotL;
}
