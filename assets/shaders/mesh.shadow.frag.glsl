#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) flat in int vMaterial;
layout(location = 2) in float vColorAlpha;
layout(location = 0) out float outDepth;

#include "meshmaterial.glsl"

void main() {
    // Shadow maps deliberately keep two-sided casting. Thin authored surfaces
    // otherwise lose their shadow when the light projection reverses winding,
    // while double-sided visible shading remains a material decision.
    int alphaMode = meshAlphaMode(vMaterial);
    if (alphaMode == 2) { discard; }
    if (alphaMode == MESH_ALPHA_MASK) {
        int base = vMaterial * MESH_MATERIAL_FLOATS;
        if (meshBaseColor(vMaterial, vUV, vec4(1.0, 1.0, 1.0, vColorAlpha)).a < materials.value[base + 6]) {
            discard;
        }
    }
    outDepth = gl_FragCoord.z;
}
