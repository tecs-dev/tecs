#version 450

layout(location = 0) in vec3 vNormal;
layout(location = 1) flat in vec3 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vTangent;
layout(location = 4) flat in int vMaterial;

layout(set = 2, binding = 0) uniform sampler2DArray images;
layout(set = 2, binding = 1) readonly buffer Materials { float value[]; } materials;

layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
layout(location = 2) out vec4 orm;
layout(location = 3) out vec4 emission;

const int MATERIAL_FLOATS = 40;
const int MATERIAL_METALLIC_ROUGHNESS = 0;
const int MATERIAL_UNLIT = 1;

vec4 sampleMap(int base, int layerLane, int uvLane, vec4 fallback) {
    float layer = materials.value[base + layerLane];
    if (layer < 0.0) { return fallback; }
    vec4 region = vec4(
        materials.value[base + uvLane],
        materials.value[base + uvLane + 1],
        materials.value[base + uvLane + 2],
        materials.value[base + uvLane + 3]);
    vec2 uv = mix(region.xy, region.zw, fract(vUV));
    return texture(images, vec3(uv, layer));
}

void main() {
    int base = vMaterial * MATERIAL_FLOATS;
    int model = int(materials.value[base]);
    vec4 baseFactor = vec4(
        materials.value[base + 28], materials.value[base + 29],
        materials.value[base + 30], materials.value[base + 31]);
    vec4 baseColor = sampleMap(base, 1, 8, vec4(1.0)) * baseFactor * vec4(vColor, 1.0);
    if (baseColor.a < materials.value[base + 6]) { discard; }

    vec3 surfaceNormal = normalize(vNormal);
    vec3 mapped = sampleMap(base, 2, 12, vec4(0.5, 0.5, 1.0, 1.0)).xyz * 2.0 - 1.0;
    mapped.xy *= materials.value[base + 38];
    vec3 tangent = normalize(vTangent.xyz);
    vec3 bitangent = normalize(cross(surfaceNormal, tangent)) * vTangent.w;
    surfaceNormal = normalize(mat3(tangent, bitangent, surfaceNormal) * mapped);

    vec4 mr = sampleMap(base, 3, 16, vec4(1.0));
    float occlusion = sampleMap(base, 4, 20, vec4(1.0)).r;
    occlusion = mix(1.0, occlusion, materials.value[base + 39]);
    float roughness = mr.g * materials.value[base + 37];
    float metallic = mr.b * materials.value[base + 36];
    vec3 emissiveFactor = vec3(
        materials.value[base + 32], materials.value[base + 33], materials.value[base + 34]);
    vec3 emitted = sampleMap(base, 5, 24, vec4(0.0)).rgb * emissiveFactor;

    if (model == MATERIAL_UNLIT) {
        albedo = vec4(baseColor.rgb, 1.0);
        normal = vec4(surfaceNormal * 0.5 + 0.5, 0.0);
        orm = vec4(1.0, 1.0, 0.0, 1.0);
        emission = vec4(emitted, max(max(emitted.r, emitted.g), emitted.b));
        return;
    }
    if (model != MATERIAL_METALLIC_ROUGHNESS) {
        albedo = vec4(1.0, 0.0, 1.0, 1.0);
        normal = vec4(surfaceNormal * 0.5 + 0.5, 1.0);
        orm = vec4(1.0, 1.0, 0.0, 1.0);
        emission = vec4(0.0);
        return;
    }

    albedo = vec4(baseColor.rgb, 1.0);
    normal = vec4(surfaceNormal * 0.5 + 0.5, 1.0);
    orm = vec4(occlusion, roughness, metallic, 1.0);
    emission = vec4(emitted, max(max(emitted.r, emitted.g), emitted.b));
}
