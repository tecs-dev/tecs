#version 450
// Writes the G-buffer. What a fragment looks like is a material's decision;
// this only supplies the inputs and honours the coverage it gets back.

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 2) in vec2 vLocal;
layout(location = 3) flat in int vMaterial;
layout(location = 4) flat in float vParam;
layout(location = 5) flat in float vLit;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2DArray images;

#include "material.glsl"
#include "materials.glsl"

void main() {
    MaterialInput frag;
    frag.local = vLocal;
    frag.uv = vUV;
    frag.color = vColor;
    frag.param = vParam;

    MaterialOutput shaded = materialDispatch(vMaterial, frag);

    // Coverage decides membership, not opacity. This pass writes with replace
    // rather than blend, so a partly covered edge fragment would overwrite what
    // is behind it instead of blending into it. Smooth edges need either
    // multisampling or the forward-blended path, both of which follow depth.
    if (shaded.coverage <= 0.0) { discard; }

    albedo = shaded.albedo;
    // The normal's alpha carries whether the fragment wants lighting, and both
    // the material and the layer have a say: the product is nonzero only where
    // the two agree, so either one asking to be left out is enough. The alpha
    // was written as one and read by nothing, so this costs no attachment and
    // no bandwidth.
    normal = vec4(0.5, 0.5, 1.0, shaded.lit * vLit);
}
