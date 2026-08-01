#version 450
// Resolves the G-buffer against the lights that reach each pixel.
//
// Works in world units. A light is a thing in the world, so the camera has to
// carry it the way it carries geometry, and the alternative of placing lights
// in target pixels on the host un-places them again the moment anything wants
// a world-space ray: the occluder mask is built with a world projection and the
// shadow march below is a world-space march. So the view arrives here and the
// fragment is taken back out to the world instead.
//
// Emission is added rather than lit. A surface that gives off light is not a
// surface a light reaches, so the term lands on top of the accumulated result:
// past the ambient, past every light, past the drop shadow, and on both sides of
// the unlit branch. That is what makes it a different thing from a material
// asking not to be lit, which replaces the lighting with the albedo instead of
// adding to it, and it is why a lamp can be lit and glowing at once.
//
// Two variants. Without shadows the pass reads the G-buffer and the lights;
// with them it reads two more targets, and the storage buffers move up two
// bindings to make room, because SDL numbers a fragment stage's sampled
// textures before its storage buffers within the same set. The block the host
// pushes is the same either way, so a pipeline built one way and driven the
// other differs in what it samples and never in what it is told.
#pragma tecs variants SHADOWS=1
#pragma tecs variants MESH_SHADOWS=1
#pragma tecs variants SHADOWS=1 MESH_SHADOWS=1
#pragma tecs variants MESH_FOG=1
#pragma tecs variants SHADOWS=1 MESH_FOG=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1
#pragma tecs variants SHADOWS=1 MESH_SHADOWS=1 MESH_FOG=1
#pragma tecs variants MESH_PBR=1
#pragma tecs variants SHADOWS=1 MESH_PBR=1
#pragma tecs variants MESH_SHADOWS=1 MESH_PBR=1
#pragma tecs variants SHADOWS=1 MESH_SHADOWS=1 MESH_PBR=1
#pragma tecs variants MESH_FOG=1 MESH_PBR=1
#pragma tecs variants SHADOWS=1 MESH_FOG=1 MESH_PBR=1
#pragma tecs variants MESH_SHADOWS=1 MESH_FOG=1 MESH_PBR=1
#pragma tecs variants SHADOWS=1 MESH_SHADOWS=1 MESH_FOG=1 MESH_PBR=1

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D gAlbedo;
layout(set = 2, binding = 1) uniform sampler2D gNormal;
// Red is ambient occlusion, green roughness and blue metallic. The latter two
// are carried for the physically based light term; the Lambert term below
// consumes only occlusion.
layout(set = 2, binding = 2) uniform sampler2D gORM;
// What each surface gives off: rgb its color, alpha how much of it. Cleared to
// zero, so a pixel nothing drew over and a surface that emits nothing read the
// same and the term below costs them a multiply.
layout(set = 2, binding = 3) uniform sampler2D gEmission;

#ifdef MESH_PBR
layout(set = 2, binding = 4) uniform sampler2D gDepth;
#define SHADOW_BINDING 5
#else
#define SHADOW_BINDING 4
#endif

#ifdef SHADOWS
// Height in red, and green marking a pixel an occluder really covers rather
// than one the blur spread a halo over.
layout(set = 2, binding = SHADOW_BINDING) uniform sampler2D occluderMask;
// One channel, half resolution: how much of all lighting reaches the ground
// here, after every drop shadow thrown across it.
layout(set = 2, binding = SHADOW_BINDING + 1) uniform sampler2D dropShadowMask;
#define LIGHT_BINDING SHADOW_BINDING + 2
#else
#define LIGHT_BINDING SHADOW_BINDING
#endif

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;      // rgb color, a intensity
};

layout(set = 2, binding = LIGHT_BINDING) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 2, binding = LIGHT_BINDING + 1) readonly buffer TileCounts {
    uint count[];
} tiles;

layout(set = 2, binding = LIGHT_BINDING + 2) readonly buffer TileLights {
    uint index[];
} tileLights;

layout(set = 3, binding = 0) uniform Scene {
    vec4 ambient;      // rgb ambient color, a says shadow targets are current
    // xy target size, zw unused. What bounds the loop below is the tile's own
    // count rather than the scene's, so the scene's is not here.
    vec4 viewport;
    // xy the camera's center in world units, zw its rotation divided through
    // by its zoom. A rotation and a scale rather than a matrix inverse: the
    // projection is orthographic, so its inverse is a 2x2 and an offset, and
    // every fragment pays two multiply-adds instead of a 4x4 by a vec4.
    vec4 view;
    // World rectangle the tile grid covers: min xy, max xy.
    vec4 bounds;
    // World to occluder-mask UV, as the four components of a 2x2 in row order.
    // The mask's projection is the camera's own widened, so it is orthographic
    // too and inverts to exactly this. At up to `steps` samples per light per
    // pixel, that is the difference between two multiply-adds and a 4x4 by a
    // vec4 on every one of them.
    vec4 maskXform;
    // xy the offset that goes with it, z how many steps a march at full
    // attenuation takes, w the world height a full-height occluder stands.
    vec4 maskParams;
#ifdef MESH_SHADOWS
    // Direction from a surface toward the mesh domain's light, with intensity
    // in w, then its color. Only mesh geometry marks itself as participating.
    vec4 meshLightDirection;
    vec4 meshLightColor;
#endif
#ifdef MESH_PBR
    vec4 meshCamera;
    mat4 inverseViewProjection;
#endif
#ifdef MESH_FOG
    vec4 meshFog;
#endif
} scene;

#include "lighting.glsl"

// Above this the green channel says an occluder really covers the pixel. Below
// it the pixel is either empty or in the halo the blur spread, and a halo that
// counted would give every silhouette a skirt of shadow it does not cast.
const float OCC_MARKER = 0.5;

// How sharply a shadow's far end fades. The ray's height crosses the occluder's
// over this much of a height, so an occluder does not simply stop blocking one
// sample later.
const float OCC_SOFT = 0.06;

// Below this a light contributes nothing a viewer could see, so the march is
// skipped rather than run at its floor of four steps. This is what makes the
// cost proportional to what a light lights rather than to what its tile covers.
const float MARCH_FLOOR = 0.05;

// The fragment's world position: the inverse of what the camera's matrix did
// to the geometry that landed here.
vec2 worldOf(vec2 fragment) {
    vec2 offset = fragment - scene.viewport.xy * 0.5;
    return scene.view.xy + vec2(
        offset.x * scene.view.z - offset.y * scene.view.w,
        offset.x * scene.view.w + offset.y * scene.view.z);
}

#ifdef MESH_PBR
vec3 meshWorldOf(vec2 uv, float depth) {
    vec4 clip = vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    vec4 world = scene.inverseViewProjection * clip;
    return world.xyz / max(abs(world.w), 1e-6) * sign(world.w);
}
#endif

#ifdef SHADOWS
vec2 maskUV(vec2 world) {
    return vec2(dot(scene.maskXform.xy, world),
                dot(scene.maskXform.zw, world)) + scene.maskParams.xy;
}

// Interleaved gradient noise, Jimenez 2014. A dither on where each sample lands
// along the ray, which turns the banding a fixed step count produces into grain
// the eye reads as softness. Cheaper than a blue-noise texture and needs no
// binding.
float dither(vec2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

// How much of one light this fragment is cut off from, zero to one.
//
// One mask and one march per light, rather than a shadow pass per light. What
// the march is testing is whether the straight line from the fragment to the
// light passes under an occluder: the line rises from the ground at the
// fragment to the light's height at the light, so at a fraction t of the way
// there it stands at t of that height, and anything taller than that blocks it.
//
// The step count follows the light's own attenuation. A pixel at the fringe of
// a light's reach marches four steps and one in the middle marches all of them,
// which bounds the worst case at what the pixels that can actually see a
// difference cost.
float marchShadow(vec2 world, vec2 lightAt, float lightHeight, float attenuation, float noise) {
    vec2 from = maskUV(world);
    vec2 to = maskUV(lightAt);

    // Self-shadow is prevented by leaving the origin's own body rather than by
    // a bias. A fragment inside an occluder takes no hit until the ray has
    // passed through empty space, so a wall does not shadow itself and still
    // shadows the wall beside it.
    bool left = texture(occluderMask, from).g <= OCC_MARKER;

    int steps = clamp(int(float(scene.maskParams.z) * attenuation + 0.5), 4, int(scene.maskParams.z));
    vec2 stride = (to - from) / float(steps);
    // Normalized against the height a full-height occluder stands, which is the
    // one number that puts a light's world height and a mask's zero-to-one
    // height in the same space.
    float rise = max(lightHeight / max(scene.maskParams.w, 1e-3), 1e-3);

    float shadow = 0.0;
    for (int step = 1; step <= steps; step++) {
        float t = (float(step) - noise) / float(steps);
        vec4 sampled = texture(occluderMask, from + stride * (float(step) - noise));
        bool solid = sampled.g > OCC_MARKER;
        if (!left) {
            left = !solid;
            continue;
        }
        if (!solid) { continue; }
        shadow = max(shadow, smoothstep(0.0, OCC_SOFT, sampled.r - t * rise));
        if (shadow >= 1.0) { break; }
    }
    return shadow;
}
#endif

void main() {
    vec4 albedo = texture(gAlbedo, vUV);
    vec4 encoded = texture(gNormal, vUV);
    vec4 emitted = texture(gEmission, vUV);
    vec3 emission = emitted.rgb * emitted.a;

    float fog = 0.0;
    bool lit = encoded.a >= 0.5;
    bool mesh = false;
#ifdef MESH_PBR
    mesh = encoded.a > 0.1 && encoded.a < 0.9;
#endif
#ifdef MESH_FOG
    // Sprites use the exact endpoints. Fog-enabled meshes use two reserved
    // middle ranges so both lit and unlit material dispatch survive the trip
    // through the normalized G-buffer.
    if (encoded.a > 0.1 && encoded.a < 0.9) {
        lit = encoded.a >= 0.5;
        fog = lit ? clamp((encoded.a - 0.50) / 0.24, 0.0, 1.0)
                  : clamp((encoded.a - 0.25) / 0.24, 0.0, 1.0);
    }
#endif

    // A material that asked not to be lit passes through at its own color,
    // plus whatever it emits: the flag says the lighting does not reach the
    // surface, and emission is the surface's own and is not lighting reaching
    // it. The G-buffer clears both attachments to zero, so anything nothing drew
    // over also takes this path and stays the clear color.
    if (!lit) {
        vec3 color = albedo.rgb + emission;
#ifdef MESH_FOG
        color = mix(color, scene.meshFog.rgb, fog);
#endif
        outColor = vec4(color, albedo.a);
        return;
    }

    // Normals are stored biased into unsigned range, as the G-buffer format
    // has no signed representation.
    vec3 normal = normalize(encoded.xyz * 2.0 - 1.0);
    vec4 orm = texture(gORM, vUV);

    // Target pixels from the top left, which is the space the view inverts
    // from and the one a readback names a pixel in.
    vec2 fragment = vUV * scene.viewport.xy;
    vec2 world = worldOf(fragment);
    vec3 surfaceWorld = vec3(world, 0.0);
    vec3 viewDirection = vec3(0.0, 0.0, 1.0);
#ifdef MESH_PBR
    if (mesh) {
        surfaceWorld = meshWorldOf(vUV, texture(gDepth, vUV).r);
        viewDirection = normalize(scene.meshCamera.xyz - surfaceWorld);
    }
#endif
    // Authored occlusion reaches indirect light only. A point light is a
    // directionally known contribution and is not hidden by a baked ambient
    // term; its own shadowing is handled separately below.
    vec3 accumulated = albedo.rgb * scene.ambient.rgb * orm.r;
#ifdef MESH_PBR
    if (mesh) {
        // Without an environment map the ambient term is a diffuse-only
        // approximation. Metals have no diffuse lobe, so only mesh pixels
        // lose it; the established 2D material contract remains Lambertian.
        accumulated *= 1.0 - orm.b;
    }
#endif
#ifdef MESH_SHADOWS
    // ORM alpha is otherwise reserved. A shadow-enabled mesh writes its
    // directional visibility into the bottom quarter; sprites and ordinary
    // meshes leave the channel at one and therefore receive no 3D sun term.
    if (orm.a < 0.5) {
        float visibility = clamp(orm.a * 4.0, 0.0, 1.0);
        accumulated += cookTorrance(albedo.rgb, normal, viewDirection,
            normalize(scene.meshLightDirection.xyz),
            scene.meshLightColor.rgb * scene.meshLightDirection.w * visibility,
            orm.g, orm.b);
    }
#endif
#ifdef SHADOWS
    float noise = dither(fragment);
#endif

    // The lights binned to this fragment's tile rather than every light in
    // the scene. Without this the loop runs its whole body for every light
    // however far away it is, since falloff clamps to zero rather than
    // rejecting, and a scene's light count would be a per-pixel cost.
    int tile = lightTileOf(world, scene.bounds);
    int count = int(tiles.count[tile]);
    int base = tile * LIGHT_TILE_SLOTS;
    for (int slot = 0; slot < count; slot++) {
        Light light = lights.item[tileLights.index[base + slot]];
        vec3 toLight = light.position.xyz - surfaceWorld;
        float distance = length(toLight);
        float radius = max(light.position.w, 1.0);

        // Smooth falloff to zero at the radius so a light has bounded reach
        // and the lighting cost stays proportional to what it touches.
        float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
        attenuation *= attenuation;

        float lambert = max(dot(normal, normalize(toLight)), 0.0);
#ifdef SHADOWS
        float reaching = attenuation * lambert;
        if (scene.ambient.a > 0.5 && reaching > MARCH_FLOOR) {
            attenuation *= 1.0 - marchShadow(world, light.position.xy, light.position.z, attenuation, noise);
        }
#endif
#ifdef MESH_PBR
        if (mesh) {
            accumulated += cookTorrance(albedo.rgb, normal, viewDirection, normalize(toLight),
                light.color.rgb * light.color.a * attenuation, orm.g, orm.b);
        } else
#endif
        {
            accumulated += albedo.rgb * light.color.rgb * light.color.a * attenuation * lambert;
        }
    }

#ifdef SHADOWS
    // After the loop and over the ambient too, which is the whole of what makes
    // this a different thing from the mask above rather than a weaker one. The
    // mask reaches a light's own contribution and has no path to the ambient
    // term at all, so in a scene lit mostly by ambient it is not merely fainter
    // than this: it is nothing.
    if (scene.ambient.a > 0.5) {
        accumulated *= texture(dropShadowMask, vUV).r;
    }
#endif

    // Added after the multiply, so no light and no shadow scales it. A glowing
    // sign is as bright in the dark as under a lamp, which is the whole of what
    // makes it a sign, and the drop shadow above darkens the ground the sign
    // stands on without dimming the sign.
    vec3 color = accumulated + emission;
#ifdef MESH_FOG
    color = mix(color, scene.meshFog.rgb, fog);
#endif
    outColor = vec4(color, albedo.a);
}
