#version 450
// Writes the G-buffer. What a fragment looks like is a material's decision;
// this only supplies the inputs and honours the coverage it gets back.

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 2) in vec2 vLocal;
layout(location = 3) flat in int vMaterial;
layout(location = 4) flat in float vParam;
layout(location = 5) flat in float vLit;
layout(location = 6) flat in int vClip;
layout(location = 7) flat in vec4 vNormalBasis;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2DArray images;

// Clip regions the packing addresses, counting region zero. `CLIPS` in
// src/tecs/gpu/instancelayout.tl is the same number.
const int CLIP_SLOTS = 256;

// Rectangles fragments are kept inside, in target pixels as minimum xy and
// maximum xy. Region zero is no clipping and holds a slot nothing reads, so a
// region index is the array index directly.
layout(set = 3, binding = 0) uniform Clips {
    vec4 region[CLIP_SLOTS];
} clips;

#include "material.glsl"
#include "materials.glsl"

void main() {
    MaterialInput frag;
    frag.local = vLocal;
    frag.uv = vUV;
    frag.color = vColor;
    frag.param = vParam;
    // This pass writes with replace, so a material that has an edge to resolve
    // has to resolve it by discarding.
    frag.blended = false;

    MaterialOutput shaded = materialDispatch(vMaterial, frag);

    // Clipping rides the coverage the material already returned rather than
    // adding a discard of its own: a fragment outside its region leaves
    // through the one below, so nothing new is early-Z's problem. `vClip` is
    // flat and zero for everything nobody clipped, so an unclipped instance
    // takes a branch its whole primitive agrees on and never touches the
    // region table.
    float coverage = shaded.coverage;
    if (vClip != 0) {
        vec4 region = clips.region[vClip];
        vec2 at = gl_FragCoord.xy;
        if (at.x < region.x || at.y < region.y
            || at.x > region.z || at.y > region.w) {
            coverage = 0.0;
        }
    }

    // Coverage decides membership, not opacity. This pass writes with replace
    // rather than blend, so a partly covered edge fragment would overwrite what
    // is behind it instead of blending into it. Smooth edges need either
    // multisampling or the forward-blended path, both of which follow depth.
    if (coverage <= 0.0) { discard; }

    albedo = shaded.albedo;

    // Out of the quad's space and into the world, which is where the lighting
    // pass works. Only the two in-plane axes turn: the quad lies in the XY
    // plane, so its perpendicular is unaffected by anything a 2x2 can do, and
    // the basis is a rotation, so what arrives unit length leaves unit length
    // and nothing has to be renormalized.
    mat2 turn = mat2(vNormalBasis.x, vNormalBasis.y,
                     vNormalBasis.z, vNormalBasis.w);
    vec3 faced = vec3(turn * shaded.normal.xy, shaded.normal.z);

    // Biased into unsigned range, since the attachment has no signed
    // representation, and the lighting pass undoes exactly this. The alpha
    // carries whether the fragment wants lighting, and both the material and
    // the layer have a say: the product is nonzero only where the two agree,
    // so either one asking to be left out is enough.
    normal = vec4(faced * 0.5 + 0.5, shaded.lit * vLit);
}
