#version 450
// The silhouette of whatever the vertex stage placed, for all three shadow
// draws.
//
// Coverage comes from the material dispatch rather than from texture alpha. The
// previous engine sampled alpha because its shadow path existed only for
// sprites and images and had a shader per shape besides; here every material
// already answers whether a fragment is part of the shape, so a circle, a
// rounded box or a glyph casts for nothing and there is one shader instead of
// five. It is also why a caster needs no alpha threshold of its own: the
// threshold a sprite would have applied is the coverage its material already
// applied.

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 2) in vec2 vLocal;
layout(location = 3) flat in int vMaterial;
layout(location = 4) flat in float vParam;
layout(location = 5) flat in float vValue;
layout(location = 0) out vec4 outValue;

layout(set = 2, binding = 0) uniform sampler2DArray images;

#include "material.glsl"
#include "materials.glsl"

void main() {
    MaterialInput frag;
    frag.local = vLocal;
    frag.uv = vUV;
    frag.color = vColor;
    frag.param = vParam;
    // A silhouette is a yes or no, so this pass wants the same membership the
    // G-buffer decided rather than a soft edge that would spread the shadow.
    frag.blended = false;

    MaterialOutput shaded = materialDispatch(vMaterial, frag);
    if (shaded.coverage <= 0.0) { discard; }

    // Green marks a pixel an occluder really covers, which is what lets the
    // raymarch tell an occluder from the halo the blur spreads around one:
    // blurring red alone would make a soft edge read as a short occluder and
    // every silhouette would grow a skirt of shadow it does not cast. The two
    // targets this writes take one channel each, and the blend is what resolves
    // overlap: max for the mask, so the tallest occluder wins, and min for the
    // shadows, so the darkest does.
    outValue = vec4(vValue, 1.0, 0.0, 1.0);
}
