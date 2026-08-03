#version 450
#pragma tecs variants MESH_SHADOWS=1
#pragma tecs variants MESH_FOG=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1
#pragma tecs variants MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_LIGHTS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_LIGHTS=1
#pragma tecs variants MESH_FOG=1 MESH_LIGHTS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_LIGHTS=1
#pragma tecs variants MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1
#pragma tecs variants MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_PROBE=1
#pragma tecs variants MESH_DOUBLE_SIDED=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_PROBE=1
#pragma tecs variants MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_PROBE=1
#pragma tecs variants MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_FOG=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1
#pragma tecs variants MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1 MESH_LIGHTS=1 MESH_LOCAL_SHADOWS=1 MESH_PROBE=1
// Shades alpha-blended mesh surfaces after deferred composition. Meshes are
// sorted back to front before this pass and use premultiplied alpha so one
// pipeline handles the complete glTF BLEND contract.

layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec4 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vTangent;
layout(location = 4) flat in int vMaterial;
layout(location = 5) in vec3 vWorld;
#ifdef MESH_FOG
layout(location = 6) in float vFog;
#endif
layout(location = 0) out vec4 outColor;

struct Light {
    vec4 position;
    vec4 color;
};

#ifdef MESH_SHADOWS
#define MESH_IMAGE_BINDING 3
#else
#define MESH_IMAGE_BINDING 0
#endif
#ifdef MESH_PROBE
#define MESH_ENVIRONMENT_BINDING MESH_IMAGE_BINDING + 1
#define MESH_LOCAL_SHADOW_BINDING MESH_ENVIRONMENT_BINDING + 1
#else
#define MESH_LOCAL_SHADOW_BINDING MESH_IMAGE_BINDING + 1
#endif
#ifdef MESH_LOCAL_SHADOWS
#define MESH_MATERIAL_BINDING MESH_LOCAL_SHADOW_BINDING + 1
#else
#define MESH_MATERIAL_BINDING MESH_LOCAL_SHADOW_BINDING
#endif
#define MESH_LIGHT_BINDING MESH_MATERIAL_BINDING + 1

#ifdef MESH_PROBE
layout(set = 2, binding = MESH_ENVIRONMENT_BINDING) uniform sampler2DArray meshEnvironment;
#endif
#ifdef MESH_LOCAL_SHADOWS
layout(set = 2, binding = MESH_LOCAL_SHADOW_BINDING) uniform sampler2D meshLocalShadowAtlas;
#endif

layout(set = 2, binding = MESH_LIGHT_BINDING) readonly buffer Lights { Light item[]; } lights;
layout(set = 2, binding = MESH_LIGHT_BINDING + 1) readonly buffer TileCounts { uint count[]; } tiles;
layout(set = 2, binding = MESH_LIGHT_BINDING + 2) readonly buffer TileLights { uint index[]; } tileLights;

layout(set = 3, binding = 1) uniform Scene {
    vec4 ambient;
    vec4 viewport;
    vec4 view;
    vec4 bounds;
    vec4 maskXform;
    vec4 maskParams;
} scene;

layout(set = 3, binding = 3) uniform Camera {
    vec4 position;
} camera;

#ifdef MESH_LOCAL_SHADOWS
layout(set = 3, binding = 5) uniform MeshLocalShadow {
    vec4 tuning;
} localShadow;
#endif

#ifdef MESH_PROBE
layout(set = 3, binding = 4) uniform MeshProbe {
    vec4 face[6];
    vec4 environmentTuning;
} probe;

#include "environment.glsl"

vec3 ambientCube(vec3 normal) {
    vec3 squared = normal * normal;
    return squared.x * probe.face[normal.x >= 0.0 ? 0 : 1].rgb
        + squared.y * probe.face[normal.y >= 0.0 ? 2 : 3].rgb
        + squared.z * probe.face[normal.z >= 0.0 ? 4 : 5].rgb;
}
#endif

#ifdef MESH_FOG
layout(set = 3, binding = 2) uniform MeshFog { vec4 color; } meshFog;
#endif

#include "meshlight.glsl"

#ifdef MESH_LIGHTS
layout(set = 2, binding = MESH_LIGHT_BINDING + 3) readonly buffer MeshLights {
    MeshLight item[];
} meshLights;
layout(set = 2, binding = MESH_LIGHT_BINDING + 4) readonly buffer MeshTileCounts {
    uint count[];
} meshTiles;
layout(set = 2, binding = MESH_LIGHT_BINDING + 5) readonly buffer MeshTileLights {
    uint index[];
} meshTileLights;
#ifdef MESH_LOCAL_SHADOWS
layout(set = 2, binding = MESH_LIGHT_BINDING + 6) readonly buffer MeshLocalShadowMatrices {
    float value[];
} meshLocalShadowMatrices;
#endif
#endif
#include "lighting.glsl"
#ifdef MESH_SHADOWS
#include "meshshadow.glsl"
#endif
#include "meshmaterial.glsl"

vec3 meshDirect(
    MeshSurface surface, vec3 viewDirection, vec3 lightDirection, vec3 radiance
) {
    if (surface.model > 1.5) {
        return lambertDirect(surface.albedo.rgb, surface.normal, lightDirection, radiance);
    }
    return cookTorrance(surface.albedo.rgb, surface.normal, viewDirection,
        lightDirection, radiance, surface.orm.g, surface.orm.b);
}

void main() {
#ifdef MESH_DOUBLE_SIDED
    if (!gl_FrontFacing && !meshDoubleSided(vMaterial)) { discard; }
#endif
    MeshSurface surface = meshMaterial(vMaterial, vUV, vColor, vNormal, vTangent);
#ifdef MESH_DOUBLE_SIDED
    if (!gl_FrontFacing) { surface.normal = -surface.normal; }
#endif
    vec3 color = surface.albedo.rgb;
    if (surface.lit >= 0.5) {
        vec3 viewDirection = normalize(camera.position.xyz - vWorld);
        bool pbr = surface.model < 0.5;
        color = surface.albedo.rgb * scene.ambient.rgb * surface.orm.r
            * (pbr ? 1.0 - surface.orm.b : 1.0);
#ifdef MESH_PROBE
        color += surface.albedo.rgb * ambientCube(surface.normal) * surface.orm.r
            * (pbr ? 1.0 - surface.orm.b : 1.0);
        if (pbr) {
            color += environmentSpecular(surface.albedo.rgb, surface.normal, viewDirection,
                surface.orm.g, surface.orm.b, surface.orm.r,
                probe.environmentTuning.x, probe.environmentTuning.zw);
        }
#endif
#ifdef MESH_SHADOWS
        vec3 sunDirection = normalize(-meshShadow.direction.xyz);
        color += meshDirect(surface, viewDirection, sunDirection,
            meshShadow.colorStrength.rgb * meshShadow.direction.w
                * meshShadowVisibility(vWorld, surface.normal));
#endif
#ifdef MESH_LIGHTS
        int tile = screenLightTileOf(gl_FragCoord.xy, scene.viewport);
        int count = int(meshTiles.count[tile]);
        int base = tile * LIGHT_TILE_SLOTS;
        for (int slot = 0; slot < count; slot++) {
            MeshLight light = meshLights.item[meshTileLights.index[base + slot]];
            vec3 toLight = light.positionRadius.xyz - vWorld;
            float distance = length(toLight);
            float attenuation = clamp(1.0 - distance / light.positionRadius.w, 0.0, 1.0);
            attenuation *= attenuation * meshLightCone(light, normalize(toLight));
#ifdef MESH_LOCAL_SHADOWS
            attenuation *= meshLocalShadowVisibility(
                light, vWorld, surface.normal, localShadow.tuning.x, localShadow.tuning.y);
#endif
            color += meshDirect(surface, viewDirection, normalize(toLight),
                light.colorIntensity.rgb * light.colorIntensity.a * attenuation);
        }
#else
        int tile = lightTileOf(vWorld.xy, scene.bounds);
        int count = int(tiles.count[tile]);
        int base = tile * LIGHT_TILE_SLOTS;
        for (int slot = 0; slot < count; slot++) {
            Light light = lights.item[tileLights.index[base + slot]];
            vec3 toLight = light.position.xyz - vWorld;
            float distance = length(toLight);
            float radius = max(light.position.w, 1.0);
            float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
            attenuation *= attenuation;
            color += meshDirect(surface, viewDirection, normalize(toLight),
                light.color.rgb * light.color.a * attenuation);
        }
#endif
    }
    color += surface.emission;
#ifdef MESH_FOG
    color = mix(color, meshFog.color.rgb, vFog);
#endif
    float alpha = clamp(surface.albedo.a, 0.0, 1.0);
    outColor = vec4(color * alpha, alpha);
}
