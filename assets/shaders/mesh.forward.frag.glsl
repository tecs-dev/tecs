#version 450
// Shades alpha-blended mesh surfaces after deferred composition. Meshes are
// sorted back to front before this pass and use premultiplied alpha so one
// pipeline handles the complete glTF BLEND contract.

layout(location = 0) in vec3 vNormal;
layout(location = 1) flat in vec3 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vTangent;
layout(location = 4) flat in int vMaterial;
layout(location = 5) in vec3 vWorld;
layout(location = 0) out vec4 outColor;

struct Light {
    vec4 position;
    vec4 color;
};

layout(set = 2, binding = 2) readonly buffer Lights { Light item[]; } lights;
layout(set = 2, binding = 3) readonly buffer TileCounts { uint count[]; } tiles;
layout(set = 2, binding = 4) readonly buffer TileLights { uint index[]; } tileLights;

layout(set = 3, binding = 1) uniform Scene {
    vec4 ambient;
    vec4 viewport;
    vec4 view;
    vec4 bounds;
    vec4 maskXform;
    vec4 maskParams;
} scene;

#include "lighting.glsl"
#include "meshmaterial.glsl"

void main() {
    MeshSurface surface = meshMaterial(vMaterial, vUV, vColor, vNormal, vTangent);
    vec3 color = surface.albedo.rgb;
    if (surface.lit >= 0.5) {
        vec3 accumulated = scene.ambient.rgb * surface.orm.r;
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
            float lambert = max(dot(surface.normal, normalize(toLight)), 0.0);
            accumulated += light.color.rgb * light.color.a * attenuation * lambert;
        }
        color *= accumulated;
    }
    color += surface.emission;
    float alpha = clamp(surface.albedo.a, 0.0, 1.0);
    outColor = vec4(color * alpha, alpha);
}
