// Evaluates one resident mesh material for both deferred and forward passes.
// The caller decides where the resulting surface lands; texture residency,
// alpha policy, tangent-space normals, and integer model dispatch stay one
// contract in both lanes.

#ifndef MESH_IMAGE_BINDING
#define MESH_IMAGE_BINDING 0
#endif
#ifndef MESH_MATERIAL_BINDING
#define MESH_MATERIAL_BINDING 1
#endif

layout(set = 2, binding = MESH_IMAGE_BINDING) uniform sampler2DArray images;
layout(set = 2, binding = MESH_MATERIAL_BINDING) readonly buffer Materials { float value[]; } materials;

const int MESH_MATERIAL_FLOATS = 40;
const int MESH_MATERIAL_METALLIC_ROUGHNESS = 0;
const int MESH_MATERIAL_UNLIT = 1;
const int MESH_MATERIAL_LAMBERT = 2;
#include "meshenums.glsl"

struct MeshSurface {
    vec4 albedo;
    vec3 normal;
    vec3 orm;
    vec3 emission;
    float lit;
    float model;
};

vec4 meshSampleMap(int base, int layerLane, int uvLane, vec2 sourceUV, vec4 fallback) {
    float layer = materials.value[base + layerLane];
    if (layer < 0.0) { return fallback; }
    vec4 region = vec4(
        materials.value[base + uvLane],
        materials.value[base + uvLane + 1],
        materials.value[base + uvLane + 2],
        materials.value[base + uvLane + 3]);
    vec2 uv = mix(region.xy, region.zw, fract(sourceUV));
    return texture(images, vec3(uv, layer));
}

int meshAlphaMode(int material) {
    return int(materials.value[material * MESH_MATERIAL_FLOATS + 7]);
}

bool meshDoubleSided(int material) {
    return materials.value[material * MESH_MATERIAL_FLOATS + 35] != 0.0;
}

vec4 meshBaseColor(int material, vec2 uv, vec4 tint) {
    int base = material * MESH_MATERIAL_FLOATS;
    vec4 baseFactor = vec4(
        materials.value[base + 28], materials.value[base + 29],
        materials.value[base + 30], materials.value[base + 31]);
    return meshSampleMap(base, 1, 8, uv, vec4(1.0))
        * baseFactor * tint;
}

MeshSurface meshMaterial(
    int material, vec2 uv, vec4 tint, vec3 vertexNormal, vec4 vertexTangent
) {
    int base = material * MESH_MATERIAL_FLOATS;
    int model = int(materials.value[base]);
    int alphaMode = int(materials.value[base + 7]);
    vec4 baseColor = meshBaseColor(material, uv, tint);
    if (alphaMode == MESH_ALPHA_MASK && baseColor.a < materials.value[base + 6]) {
        discard;
    }

    vec3 surfaceNormal = normalize(vertexNormal);
    vec3 mapped = meshSampleMap(base, 2, 12, uv, vec4(0.5, 0.5, 1.0, 1.0)).xyz * 2.0 - 1.0;
    mapped.xy *= materials.value[base + 38];
    vec3 tangent = normalize(vertexTangent.xyz);
    vec3 bitangent = normalize(cross(surfaceNormal, tangent)) * vertexTangent.w;
    surfaceNormal = normalize(mat3(tangent, bitangent, surfaceNormal) * mapped);

    vec4 mr = meshSampleMap(base, 3, 16, uv, vec4(1.0));
    float occlusion = meshSampleMap(base, 4, 20, uv, vec4(1.0)).r;
    occlusion = mix(1.0, occlusion, materials.value[base + 39]);
    float roughness = mr.g * materials.value[base + 37];
    float metallic = mr.b * materials.value[base + 36];
    vec3 emissiveFactor = vec3(
        materials.value[base + 32], materials.value[base + 33], materials.value[base + 34]);
    vec3 emitted = meshSampleMap(base, 5, 24, uv, vec4(0.0)).rgb * emissiveFactor;

    MeshSurface surface;
    surface.albedo = baseColor;
    surface.normal = surfaceNormal;
    surface.orm = vec3(occlusion, roughness, metallic);
    surface.emission = emitted;
    surface.lit = 1.0;
    surface.model = float(model);
    if (model == MESH_MATERIAL_UNLIT) {
        surface.orm = vec3(1.0, 1.0, 0.0);
        surface.lit = 0.0;
    } else if (model != MESH_MATERIAL_METALLIC_ROUGHNESS && model != MESH_MATERIAL_LAMBERT) {
        surface.albedo = vec4(1.0, 0.0, 1.0, baseColor.a);
        surface.orm = vec3(1.0, 1.0, 0.0);
        surface.emission = vec3(0.0);
    }
    return surface;
}
