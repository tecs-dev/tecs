#version 450
#pragma tecs variants MESH_SHADOWS=1

layout(location = 0) in vec3 vNormal;
layout(location = 1) flat in vec3 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vTangent;
layout(location = 4) flat in int vMaterial;
layout(location = 5) in vec3 vWorld;

layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
layout(location = 2) out vec4 orm;
layout(location = 3) out vec4 emission;

#ifdef MESH_SHADOWS
#define MESH_IMAGE_BINDING 1
#define MESH_MATERIAL_BINDING 2
#include "meshshadow.glsl"
#endif
#include "meshmaterial.glsl"

void main() {
    MeshSurface surface = meshMaterial(vMaterial, vUV, vColor, vNormal, vTangent);
    albedo = vec4(surface.albedo.rgb, 1.0);
    normal = vec4(surface.normal * 0.5 + 0.5, surface.lit);
#ifdef MESH_SHADOWS
    // The bottom quarter of reserved ORM alpha marks a shadow-enabled mesh
    // and carries its directional visibility to the deferred light resolve.
    orm = vec4(surface.orm, meshShadowVisibility(vWorld, surface.normal) * 0.25);
#else
    orm = vec4(surface.orm, 1.0);
#endif
    float emitted = max(max(surface.emission.r, surface.emission.g), surface.emission.b);
    emission = vec4(surface.emission, emitted);
}
