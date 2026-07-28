#version 450
// Fills the shadow lane's list, one run of `CAST_FANOUT` entries per caster.
//
// The same compaction the drawing lanes run, against the same slots and the
// same block bases, so the list is ordered by instance and is the same list for
// the same scene every frame. What differs is that an entry is not an instance
// index: it names the instance and the light whose copy of it this entry is,
// and a caster's run is a fixed length so an entry's rank is its position and
// costs no bits.
//
// The light loop runs here rather than in the mark pass, and exactly once. Mark
// stays a bounds-only pass over every instance in the world, drawn or not,
// which is what keeps it cheap at four million; this runs over the same range
// but does its loop only for the handful of instances that reached the lane.
// Emitting a conservative count there and resolving it here is also what keeps
// the two from disagreeing: a count computed twice from two loops is a list
// that corrupts the first time they differ.
//
// Which lights a caster keeps is decided by weight rather than by buffer order.
// A cap that binds by buffer order drops whichever shadow happens to sit later
// in the light buffer, which can be the brightest, and makes shadows pop when
// an unrelated light is spawned and the slots shift. By weight the caster loses
// its faintest, which is what a viewer would have chosen, and the choice is
// stable across frames because the ordering is by a value the scene defines.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Slots { uint slot[]; } slots;
layout(set = 0, binding = 1) readonly buffer Bases { uint base[]; } bases;
layout(set = 0, binding = 2) readonly buffer Bounds { vec4 item[]; } bounds;

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;      // rgb color, a intensity
};

layout(set = 0, binding = 3) readonly buffer Lights { Light item[]; } lights;

layout(set = 1, binding = 0) writeonly buffer CastList { uint entry[]; } list;

layout(set = 2, binding = 0) uniform Cull {
    vec4 view;
    // x instance count, y workgroup count, z the list's capacity in entries,
    // w unread here: this pass fills one lane and knows which.
    vec4 params;
    // x the shadow margin the mark pass tested with, unread here. y how many
    // lights the buffer holds this frame.
    vec4 extra;
} cull;

#include "cull.glsl"
#include "cast.glsl"

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.x)) { return; }
    uint offset = (slots.slot[i] >> laneShift(LANE_CAST)) & LANE_MASK;
    if (offset == CULLED) { return; }

    uint at = bases.base[gl_WorkGroupID.x] + offset;
    // A run is dropped whole rather than truncated. Half a run would leave a
    // caster's later entries holding whatever the last frame wrote there, and
    // the rank a draw derives from a position would name the wrong caster.
    if (at + CAST_FANOUT > uint(cull.params.z)) { return; }

    vec4 box = bounds.item[i];

    if (cullOccluder(box)) {
        // An occluder's silhouette goes into the mask once, at its own
        // transform. The rest of its run is filled rather than left, because a
        // stale entry from an earlier frame draws a shadow for an instance that
        // has gone.
        list.entry[at] = castPack(i, CAST_NONE);
        for (uint k = 1u; k < CAST_FANOUT; k++) {
            list.entry[at + k] = castPack(i, CAST_EMPTY);
        }
        return;
    }

    // Where the caster meets the ground, which is the bottom of its bound: a
    // shadow is thrown from a thing's feet and not from its middle.
    vec2 foot = vec2(box.x, box.y + abs(box.w));

    // The four strongest, kept by a fixed comparison network rather than by
    // indexing an array, so there is no dynamic indexing inside a loop that is
    // already running. Ties keep the light earlier in the buffer, which is what
    // makes the result the same for the same scene rather than the same for the
    // same schedule. The width here is `CAST_FANOUT` written out; the two only
    // work while they agree.
    float w0 = 0.0, w1 = 0.0, w2 = 0.0, w3 = 0.0;
    uint s0 = CAST_EMPTY, s1 = CAST_EMPTY, s2 = CAST_EMPTY, s3 = CAST_EMPTY;

    uint lightCount = uint(cull.extra.y);
    for (uint l = 0u; l < lightCount; l++) {
        Light light = lights.item[l];
        vec3 toLight = vec3(light.position.xy - foot, light.position.z);
        float w = castWeight(toLight, light.position.w, light.color.a);
        if (w < CAST_MIN_WEIGHT) { continue; }

        if (w > w0) {
            w3 = w2; s3 = s2; w2 = w1; s2 = s1; w1 = w0; s1 = s0; w0 = w; s0 = l;
        } else if (w > w1) {
            w3 = w2; s3 = s2; w2 = w1; s2 = s1; w1 = w; s1 = l;
        } else if (w > w2) {
            w3 = w2; s3 = s2; w2 = w; s2 = l;
        } else if (w > w3) {
            w3 = w; s3 = l;
        }
    }

    list.entry[at] = castPack(i, s0);
    list.entry[at + 1u] = castPack(i, s1);
    list.entry[at + 2u] = castPack(i, s2);
    list.entry[at + 3u] = castPack(i, s3);
}
