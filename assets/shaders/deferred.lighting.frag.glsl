#version 450
// Resolves the G-buffer against the lights that reach each pixel.
//
// Works in world units. A light is a thing in the world, so the camera has to
// carry it the way it carries geometry, and the alternative of placing lights
// in target pixels on the host un-places them again the moment anything wants
// a world-space ray: an occluder mask is built with a world projection and a
// shadow march is a world-space march. So the view arrives here and the
// fragment is taken back out to the world instead.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D gAlbedo;
layout(set = 2, binding = 1) uniform sampler2D gNormal;

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;      // rgb colour, a intensity
};

layout(set = 2, binding = 2) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 2, binding = 3) readonly buffer TileCounts {
    uint count[];
} tiles;

layout(set = 2, binding = 4) readonly buffer TileLights {
    uint index[];
} tileLights;

layout(set = 3, binding = 0) uniform Scene {
    vec4 ambient;      // rgb ambient colour, a unused
    // xy target size, zw unused. What bounds the loop below is the tile's own
    // count rather than the scene's, so the scene's is not here.
    vec4 viewport;
    // xy the camera's centre in world units, zw its rotation divided through
    // by its zoom. A rotation and a scale rather than a matrix inverse: the
    // projection is orthographic, so its inverse is a 2x2 and an offset, and
    // every fragment pays two multiply-adds instead of a 4x4 by a vec4.
    vec4 view;
    // World rectangle the tile grid covers: min xy, max xy.
    vec4 bounds;
} scene;

#include "lighting.glsl"

// The fragment's world position: the inverse of what the camera's matrix did
// to the geometry that landed here.
vec2 worldOf(vec2 fragment) {
    vec2 offset = fragment - scene.viewport.xy * 0.5;
    return scene.view.xy + vec2(
        offset.x * scene.view.z - offset.y * scene.view.w,
        offset.x * scene.view.w + offset.y * scene.view.z);
}

void main() {
    vec4 albedo = texture(gAlbedo, vUV);
    vec4 encoded = texture(gNormal, vUV);

    // A material that asked not to be lit passes through at its own colour.
    // The G-buffer clears this to zero, so anything nothing drew over also
    // takes this path and stays the clear colour rather than picking up
    // ambient.
    if (encoded.a < 0.5) {
        outColor = albedo;
        return;
    }

    // Normals are stored biased into unsigned range, as the G-buffer format
    // has no signed representation.
    vec3 normal = normalize(encoded.xyz * 2.0 - 1.0);

    // Target pixels from the top left, which is the space the view inverts
    // from and the one a readback names a pixel in.
    vec2 fragment = vUV * scene.viewport.xy;
    vec2 world = worldOf(fragment);
    vec3 accumulated = scene.ambient.rgb;

    // The lights binned to this fragment's tile rather than every light in
    // the scene. Without this the loop runs its whole body for every light
    // however far away it is, since falloff clamps to zero rather than
    // rejecting, and a scene's light count would be a per-pixel cost.
    int tile = lightTileOf(world, scene.bounds);
    int count = int(tiles.count[tile]);
    int base = tile * LIGHT_TILE_SLOTS;
    for (int slot = 0; slot < count; slot++) {
        Light light = lights.item[tileLights.index[base + slot]];
        vec3 toLight = vec3(light.position.xy - world, light.position.z);
        float distance = length(toLight);
        float radius = max(light.position.w, 1.0);

        // Smooth falloff to zero at the radius so a light has bounded reach
        // and the lighting cost stays proportional to what it touches.
        float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
        attenuation *= attenuation;

        float lambert = max(dot(normal, normalize(toLight)), 0.0);
        accumulated += light.color.rgb * light.color.a * attenuation * lambert;
    }

    outColor = vec4(albedo.rgb * accumulated, albedo.a);
}
