#version 450
#pragma tecs variants MESH_SHADOWS=1
#pragma tecs variants MESH_FOG=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1
#pragma tecs variants MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_SHADOWS=1 MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_FOG=1 MESH_DOUBLE_SIDED=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_DOUBLE_SIDED=1

layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec4 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vTangent;
layout(location = 4) flat in int vMaterial;
layout(location = 5) in vec3 vWorld;
#ifdef MESH_FOG
layout(location = 6) in float vFog;
#endif

layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
layout(location = 2) out vec4 orm;
layout(location = 3) out vec4 emission;

#ifdef MESH_SHADOWS
#define MESH_IMAGE_BINDING 3
#define MESH_MATERIAL_BINDING 4
#include "meshshadow.glsl"
#endif
#include "meshmaterial.glsl"

void main() {
    MeshSurface surface = meshMaterial(vMaterial, vUV, vColor, vNormal, vTangent);
#ifdef MESH_DOUBLE_SIDED
    if (!gl_FrontFacing) { surface.normal = -surface.normal; }
#endif
    albedo = vec4(surface.albedo.rgb, 1.0);
#ifdef MESH_FOG
    // Exact zero and one remain the sprite markers. Three disjoint middle
    // ranges preserve unlit, Lambert, and PBR mesh dispatch while carrying a
    // quantized fog factor through the normalized attachment.
    const float FOG_SPAN = 31.0 / 255.0;
    float modelMarker = surface.model < 0.5 ? 160.0 / 255.0
        : surface.model < 1.5 ? 32.0 / 255.0
        : 96.0 / 255.0;
    float fogMarker = modelMarker + vFog * FOG_SPAN;
    normal = vec4(surface.normal * 0.5 + 0.5, fogMarker);
#else
    float modelMarker = surface.model < 0.5 ? 160.0 / 255.0
        : surface.model < 1.5 ? 32.0 / 255.0
        : 96.0 / 255.0;
    normal = vec4(surface.normal * 0.5 + 0.5, modelMarker);
#endif
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
