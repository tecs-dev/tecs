#version 450
// Shades a blended instance and hands it to the blend, after compositing.
//
// The same material dispatch the G-buffer pass runs, followed by the same light
// loop the resolve runs, because a fragment that never reaches the G-buffer has
// to do both itself. That is what a forward pass is, and it is why this is a
// forward pass rather than an unlit overlay: an entity is routed here by its
// alpha, so an alpha crossing one has to change how much of the fragment lands
// and nothing else. Lighting it here is what keeps that true.
//
// A particle from a blended effect arrives the same way, its bound written by
// `particle.simulate.comp.glsl` rather than by extraction, and carries a blend
// mode in `origin.z` that says whether it blends over what is behind it or adds
// to it.
//
// What the fragment does not do is write the G-buffer, so blended content is
// invisible to anything that reads it: it casts no shadow a later pass could
// build from its normal, and its emission reaches no pass that reads the
// emission attachment. That follows from running after the resolve and is the
// price of the pass. What it does do is add its own emission to its own color,
// because a translucent thing that glows is an ordinary effect and the material
// has already answered: the term is a multiply-add here and the alternative
// would be a glow that vanishes the moment a fade takes an entity below one.

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 2) in vec2 vLocal;
layout(location = 3) flat in int vMaterial;
layout(location = 4) flat in float vParam;
layout(location = 5) flat in float vLit;
layout(location = 6) flat in int vClip;
layout(location = 7) flat in vec4 vNormalBasis;
layout(location = 8) flat in int vBlend;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray images;

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;      // rgb color, a intensity
};

layout(set = 2, binding = 1) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 2, binding = 2) readonly buffer TileCounts {
    uint count[];
} tiles;

layout(set = 2, binding = 3) readonly buffer TileLights {
    uint index[];
} tileLights;

// Clip regions the packing addresses, counting region zero. `CLIPS` in
// src/tecs/gpu/instancelayout.tl is the same number.
const int CLIP_SLOTS = 256;

layout(set = 3, binding = 0) uniform Clips {
    vec4 region[CLIP_SLOTS];
} clips;

// The same block the resolve reads, pushed by the same code, so a blended
// fragment and the opaque one behind it are lit by one description of the
// scene rather than by two that have to be kept in step. The last two are the
// mask transform, which this pass is handed and does not use: blended geometry
// is neither shadowed nor an occluder, because it never reaches the G-buffer
// and a hard silhouette of something half transparent would be a lie. Declared
// so the block is one description rather than two of different lengths.
layout(set = 3, binding = 1) uniform Scene {
    vec4 ambient;
    vec4 viewport;
    vec4 view;
    vec4 bounds;
    vec4 maskXform;
    vec4 maskParams;
} scene;

#include "lighting.glsl"
#include "material.glsl"
#include "materials.glsl"
// For the blend modes alone. The vertex shader reads the mode out of `origin.z`
// and this names the value it wrote, so the two cannot disagree about which
// number means which mode.
#include "slot.glsl"

// The fragment's world position, inverting exactly what the camera's matrix did
// to the geometry that landed here. Taken from the fragment rather than
// interpolated from the vertex, because the resolve does it this way and the
// two have to agree about where a pixel is: a layer with parallax moves its
// geometry and this inverse is what the resolve would have recovered for the
// same pixel.
vec2 worldOf(vec2 fragment) {
    vec2 offset = fragment - scene.viewport.xy * 0.5;
    return scene.view.xy + vec2(
        offset.x * scene.view.z - offset.y * scene.view.w,
        offset.x * scene.view.w + offset.y * scene.view.z);
}

void main() {
    MaterialInput frag;
    frag.local = vLocal;
    frag.uv = vUV;
    frag.color = vColor;
    frag.param = vParam;
    // The one pass that blends, so a material with an edge to resolve puts it in
    // alpha here instead of discarding it. This is what makes a soft-edged
    // sprite soft: the same texel that the G-buffer pass has to keep or drop
    // whole lands here at whatever fraction the artwork drew.
    frag.blended = true;

    MaterialOutput shaded = materialDispatch(vMaterial, frag);

    float coverage = shaded.coverage;
    if (vClip != 0) {
        vec4 region = clips.region[vClip];
        vec2 at = gl_FragCoord.xy;
        if (at.x < region.x || at.y < region.y
            || at.x > region.z || at.y > region.w) {
            coverage = 0.0;
        }
    }

    // Membership, read exactly as the G-buffer pass reads it: coverage says
    // whether the fragment is part of the shape and alpha says how much of what
    // is behind it survives, and conflating the two would make a shape's own
    // silhouette into a fade. What differs is where a material puts the boundary,
    // which is what `frag.blended` above told it, and not what this does with the
    // answer.
    if (coverage <= 0.0) { discard; }

    vec3 color = shaded.albedo.rgb;
    if (shaded.lit * vLit >= 0.5) {
        // The quad's own space out into the world, the same turn the G-buffer
        // pass applies before it stores a normal.
        mat2 turn = mat2(vNormalBasis.x, vNormalBasis.y,
                         vNormalBasis.z, vNormalBasis.w);
        vec3 normal = normalize(vec3(turn * shaded.normal.xy, shaded.normal.z));

        vec2 world = worldOf(gl_FragCoord.xy);
        vec3 accumulated = scene.ambient.rgb;

        int tile = lightTileOf(world, scene.bounds);
        int count = int(tiles.count[tile]);
        int base = tile * LIGHT_TILE_SLOTS;
        for (int slot = 0; slot < count; slot++) {
            Light light = lights.item[tileLights.index[base + slot]];
            vec3 toLight = vec3(light.position.xy - world, light.position.z);
            float distance = length(toLight);
            float radius = max(light.position.w, 1.0);

            float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
            attenuation *= attenuation;

            float lambert = max(dot(normal, normalize(toLight)), 0.0);
            accumulated += light.color.rgb * light.color.a * attenuation * lambert;
        }
        color *= accumulated;
    }

    // On top of the lighting rather than inside it, exactly as the resolve adds
    // it, so the two lanes agree about what a glow is.
    color += shaded.emission.rgb * shaded.emission.a;

    // Premultiplied, because that is what makes one pipeline serve two modes.
    // The pipeline takes the color as it is and the target scaled by one minus
    // this alpha, so scaling the color here is what alpha blending needs, and
    // writing an alpha of zero while keeping that scaled color leaves the target
    // untouched and adds to it instead. Alpha over and additive therefore differ
    // in one component of one write, and both interleave correctly in the one
    // sorted list rather than one of them being a second pass over all of it.
    //
    // The emission above is inside that scale, which is right: a fifth-opaque
    // pane lets a fifth of what is behind it through and gives off a fifth of
    // the light a solid one would.
    float alpha = clamp(shaded.albedo.a, 0.0, 1.0);
    outColor = vec4(color * alpha, vBlend == BLEND_ADDITIVE ? 0.0 : alpha);
}
