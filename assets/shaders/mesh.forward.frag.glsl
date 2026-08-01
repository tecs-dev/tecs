#version 450
#pragma tecs variants MESH_SHADOWS=1
#pragma tecs variants MESH_FOG=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1
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
#define MESH_IMAGE_BINDING 1
#define MESH_MATERIAL_BINDING 2
#define MESH_LIGHT_BINDING 3
#else
#define MESH_LIGHT_BINDING 2
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

#ifdef MESH_FOG
layout(set = 3, binding = 2) uniform MeshFog { vec4 color; } meshFog;
#endif

#include "lighting.glsl"
#ifdef MESH_SHADOWS
#include "meshshadow.glsl"
#endif
#include "meshmaterial.glsl"

void main() {
    MeshSurface surface = meshMaterial(vMaterial, vUV, vColor, vNormal, vTangent);
    vec3 color = surface.albedo.rgb;
    if (surface.lit >= 0.5) {
        vec3 viewDirection = normalize(camera.position.xyz - vWorld);
        color = surface.albedo.rgb * scene.ambient.rgb * surface.orm.r * (1.0 - surface.orm.b);
#ifdef MESH_SHADOWS
        vec3 sunDirection = normalize(-meshShadow.direction.xyz);
        color += cookTorrance(surface.albedo.rgb, surface.normal, viewDirection, sunDirection,
            meshShadow.colorStrength.rgb * meshShadow.direction.w
                * meshShadowVisibility(vWorld, surface.normal),
            surface.orm.g, surface.orm.b);
#endif
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
            color += cookTorrance(surface.albedo.rgb, surface.normal, viewDirection, normalize(toLight),
                light.color.rgb * light.color.a * attenuation, surface.orm.g, surface.orm.b);
        }
    }
    color += surface.emission;
#ifdef MESH_FOG
    color = mix(color, meshFog.color.rgb, vFog);
#endif
    float alpha = clamp(surface.albedo.a, 0.0, 1.0);
    outColor = vec4(color * alpha, alpha);
}
