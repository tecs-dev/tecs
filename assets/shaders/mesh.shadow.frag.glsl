#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) flat in int vMaterial;
layout(location = 0) out float outDepth;

#include "meshmaterial.glsl"

void main() {
    int alphaMode = meshAlphaMode(vMaterial);
    if (alphaMode == 2) { discard; }
    if (alphaMode == MESH_ALPHA_MASK) {
        int base = vMaterial * MESH_MATERIAL_FLOATS;
        if (meshBaseColor(vMaterial, vUV, vec3(1.0)).a < materials.value[base + 6]) {
            discard;
        }
    }
    outDepth = gl_FragCoord.z;
}
