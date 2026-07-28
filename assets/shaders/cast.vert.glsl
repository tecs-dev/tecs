#version 450
// Places one entry of the shadow lane's list, for whichever of the three draws
// is running.
//
// Three draws and one shader, because all three place a quad from the same
// instance record against the same list and differ only in where they put it
// and what they reject. The occluder mask draws a caster's own silhouette; the
// drop-shadow pass draws it again stretched away from each light that reaches
// it; the stamp draws it once more at its own transform, to put the caster back
// on top of the shadow it threw. Splitting them into three shaders would mean
// three copies of the placement and the playback resolve.
//
// What is deliberately not here is the layer table. An occluder blocks light in
// the world and a shadow lands on the ground in the world, so both are placed
// by the camera and neither takes a layer's parallax, screen-space placement or
// ignored zoom. A caster on a screen-space layer casts nothing, which is what
// it should do: there is no ground under the heads-up display.

struct Instance {
    vec4 xform;   // rotation, scaleX, scaleY, depth
    vec4 origin;  // xy world position, z clip region, array layer and height, w material
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;      // rgb colour, a intensity
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer CastList { uint entry[]; } list;
layout(set = 0, binding = 3) readonly buffer Lights { Light item[]; } lights;

#define PLAYBACK_SET 0
#define PLAYBACK_BINDING 2
#include "playback.glsl"
#include "slot.glsl"
#include "cast.glsl"

layout(set = 1, binding = 0) uniform Caster {
    // The projection to place with. The mask's is the camera's widened so the
    // shadow margin lands inside the target; the other two draws take the
    // camera's own, because what they write is read at the fragment's own pixel.
    mat4 viewProjection;
    // x the animation clock in whole fixed steps, y which of the three draws
    // this is, z how dark a drop shadow is at full weight, w the longest a
    // shadow may be in world units.
    vec4 params;
} caster;

// Which draw is running. The pass is one pipeline per blend mode and one
// uniform per draw, so this selects rather than being compiled in.
const float CAST_MODE_MASK = 0.0;
const float CAST_MODE_SHADOW = 1.0;
const float CAST_MODE_STAMP = 2.0;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;
layout(location = 2) out vec2 vLocal;
layout(location = 3) flat out int vMaterial;
layout(location = 4) flat out float vParam;
// What the fragment writes where it is covered: the caster's height for the
// mask, and one less the shadow's darkness for the other two. Flat, because it
// is the instance's and the light's rather than the fragment's.
layout(location = 5) flat out float vValue;

const vec2 CORNERS[4] = vec2[4](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5),
    vec2(-0.5,  0.5), vec2( 0.5,  0.5)
);

// Off the front of the near plane and the same point for all four corners, so
// the primitive has no area at all rather than a small one somewhere.
void reject() {
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    vColor = vec4(0.0);
    vUV = vec3(0.0);
    vLocal = vec2(0.0);
    vMaterial = 0;
    vParam = 0.0;
    vValue = 0.0;
}

void main() {
    uint entry = list.entry[gl_InstanceIndex];
    uint light = castLight(entry);
    // Every caster's run is the same length, so which copy of it this is comes
    // from the position rather than from a field.
    uint rank = uint(gl_InstanceIndex) % CAST_FANOUT;
    float mode = caster.params.y;

    // An occluder's entries say so by naming no light, which is also what tells
    // the two drop-shadow draws to leave it alone: it darkens nothing, it
    // blocks.
    bool named = light == CAST_NONE;
    if (mode == CAST_MODE_MASK) {
        if (!named) { reject(); return; }
    } else if (mode == CAST_MODE_STAMP) {
        if (named || rank != 0u) { reject(); return; }
    } else {
        if (light >= CAST_EMPTY) { reject(); return; }
    }

    Instance self = instances.item[castInstance(entry)];

    float angle = self.xform.x;
    float sx = self.xform.y;
    float sy = self.xform.z;
    float c = cos(angle);
    float s = sin(angle);
    mat2 basis = mat2(c * sx, s * sx, -s * sy, c * sy);

    // The same resolve the G-buffer pass runs, so an animated caster's
    // silhouette is the frame it is showing rather than the one it was written
    // with.
    vec4 region = self.uvRect;
    float frameLayer = -1.0;
    vec2 pivotOffset = vec2(0.0);
    if (isPlayback(region)) {
        Playback frame = resolvePlayback(region, caster.params.x);
        region = frame.rect;
        frameLayer = frame.layer;
        pivotOffset = frame.pivot;
    }

    vec2 corner = CORNERS[gl_VertexIndex];
    float packedSlot = self.origin.z;
    float arrayLayer = slotLayer(packedSlot);
    if (frameLayer >= 0.0) { arrayLayer = frameLayer; }
    float height = slotHeight(packedSlot);

    vec2 world;
    if (mode == CAST_MODE_SHADOW) {
        // Where the caster meets the ground, which is the bottom edge of its
        // quad: a shadow is thrown from a thing's feet and not from its middle.
        vec2 foot = self.origin.xy + basis * (vec2(0.0, 0.5) - pivotOffset);
        Light lit = lights.item[light];
        vec2 toLight = lit.position.xy - foot;
        float ground = length(toLight);
        // A light directly over the caster throws no shadow in any direction,
        // and there is no direction to throw it in either.
        if (ground < 1e-4) { reject(); return; }
        vec2 away = -toLight / ground;

        // How tall the caster stands, in the units its own quad is drawn in. A
        // height of one is a thing as tall as it is wide on screen, which is
        // what an upright sprite is.
        float tall = height * abs(sy);
        // Where the tip of the shadow lands, which is similar triangles and
        // nothing else: the light at height Lz over a caster of height h throws
        // the caster's top to h / (Lz - h) of the horizontal distance beyond
        // its feet. A light at or below the caster's own height would throw it
        // to infinity, so the length is bounded rather than the formula being
        // guarded twice.
        float reach = ground * tall / max(lit.position.z - tall, 1e-3);
        reach = clamp(reach, 0.0, caster.params.w);

        // The silhouette laid down: its bottom edge stays at the feet and its
        // top edge goes to the tip, so the whole shape stretches along the
        // ground rather than sliding down it.
        vec2 across = vec2(-away.y, away.x);
        world = foot + across * (corner.x * sx) + away * ((0.5 - corner.y) * reach);

        float weight = castWeight(vec3(toLight, lit.position.z),
                                  lit.position.w, lit.color.a);
        vValue = 1.0 - clamp(caster.params.z * weight, 0.0, 1.0);
    } else {
        world = self.origin.xy + basis * (corner - pivotOffset);
        // The mask carries the height the raymarch measures a shadow's reach
        // against. The stamp carries no darkness at all, which is the whole of
        // what it is for: it puts the caster back at full brightness over the
        // shadow it threw across its own feet.
        vValue = mode == CAST_MODE_MASK ? height : 1.0;
    }

    gl_Position = caster.viewProjection * vec4(world, 0.0, 1.0);
    // Nothing here tests depth, so the value only has to be inside the range
    // the clip volume accepts.
    gl_Position.z = 0.5 * gl_Position.w;

    vColor = self.color;
    vUV = vec3(mix(region.xy, region.zw, corner + 0.5), arrayLayer);
    vLocal = corner;
    float packed = self.origin.w;
    vMaterial = int(floor(packed));
    vParam = fract(packed);
}
