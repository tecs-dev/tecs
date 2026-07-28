#version 450
// Marks what survives the view test, sorts it into a lane, and prefixes it
// within its workgroup.
//
// Three passes rather than one atomic append, because an atomic gives no
// ordering: the compacted list comes out differently every frame, so
// overlapping geometry swaps which one wins and the scene shimmers. A scan is
// deterministic, so the same scene draws the same way every frame.
//
// Three lanes rather than one, because what the G-buffer rasterises, what the
// forward pass blends and what casts a shadow are three different lists over
// one set of instances. A blended instance must not reach the G-buffer: that
// pass writes with replace and has nowhere to put partial coverage, so an
// instance carrying an alpha below one leaves here for the forward pass
// instead. A caster is in whichever of those two its alpha put it and in the
// shadow lane as well, because a wall both draws and blocks light.
//
// All three are scanned in the same dispatch, over the one bound read the pass
// already pays for. A `uvec3` add under the same barriers is the same scan run
// three times in parallel rather than three times in sequence, so the barrier
// count is what it was and the shared memory is three kilobytes instead of one.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds {
    vec4 item[];   // xy centre, zw half extent
} bounds;

layout(set = 1, binding = 0) writeonly buffer Slots { uint slot[]; } slots;
layout(set = 1, binding = 1) writeonly buffer Counts { uint count[]; } counts;
layout(set = 1, binding = 2) writeonly buffer BlendCounts {
    uint count[];
} blendCounts;
layout(set = 1, binding = 3) writeonly buffer CastCounts {
    uint count[];
} castCounts;
layout(set = 2, binding = 0) uniform Cull {
    // World-space rectangle the camera can see: min xy, max xy.
    vec4 view;
    // Instance count, workgroup count, then the two fields the later passes
    // read: the destination list's capacity and which lane is being filled.
    vec4 params;
    // x how far outside the view a caster is still kept, in world units. The
    // rest is spare.
    vec4 extra;
} cull;

#include "cull.glsl"
#include "cast.glsl"

shared uvec3 scratch[256];

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;

    uvec3 keep = uvec3(0u);
    if (i < uint(cull.params.x)) {
        vec4 box = bounds.item[i];
        // Neither sign says anything about length, so the view test works from
        // the magnitude of both.
        vec2 extent = abs(box.zw);
        // Tested in world space now that a camera exists, so panning and
        // zooming change what survives rather than only what is drawn.
        bool outside = box.x + extent.x < cull.view.x || box.x - extent.x > cull.view.z ||
                       box.y + extent.y < cull.view.y || box.y - extent.y > cull.view.w;
        keep.x = outside ? 0u : 1u;
        // A survivor goes to one drawing lane or the other and never to both,
        // so the two lists partition what the view kept rather than
        // overlapping.
        if (keep.x == 1u && cullBlended(box)) {
            keep.x = 0u;
            keep.y = 1u;
        }
        // The shadow lane's own test, against a rectangle wider than the view.
        // A caster just off the left edge throws a shadow that falls on screen,
        // and the ordinary view test drops it: the previous engine expanded its
        // light cull for exactly this and could not expand its drop-shadow
        // fan-out, which lived inside the sprite cull and inherited the
        // viewport. Here the lane's predicate is its own.
        //
        // The count is the fan-out rather than one. A prefix sum over counts is
        // the same prefix sum, so this costs nothing beyond what the lane
        // already costs, and it is what lets the compaction give every caster a
        // fixed run without a second pass to tell it where the runs are.
        if (cullCasts(box)) {
            float margin = cull.extra.x;
            bool far = box.x + extent.x < cull.view.x - margin ||
                       box.x - extent.x > cull.view.z + margin ||
                       box.y + extent.y < cull.view.y - margin ||
                       box.y - extent.y > cull.view.w + margin;
            keep.z = far ? 0u : CAST_FANOUT;
        }
        // A clip region is not tested here, and the fragment stage is where an
        // instance outside its region is thrown away. The test would need the
        // region table, which is a uniform and cheap, and the instance's clip
        // index, which is not: it rides in the 64-byte instance, and this pass
        // reads the 16-byte bound for every entity in the world every frame,
        // drawn or not. The bound's two signs are already the role, so there is
        // nowhere in it to put eight bits of region.
        //
        // The payoff is on the other side of the same wall. A panel with a
        // scrollable list is what clips, and it sits on a layer the view does
        // not describe, which writes an UNBOUNDED extent so no view rejects it;
        // an unbounded box overlaps every rectangle, so a region test keeps it
        // too. What is left is world content inside the view and outside its
        // region, which is the narrow half of the case, bought with a gather
        // for every entity in the world.
    }

    // Inclusive scan across the workgroup, once per lane. Each survivor learns
    // how many entries of its own lane precede it here, which is its offset
    // inside this block of that lane's list.
    scratch[t] = keep;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uvec3 carried = uvec3(0u);
        if (t >= stride) {
            carried = scratch[t - stride];
        }
        barrier();
        scratch[t] += carried;
        barrier();
    }

    if (i < uint(cull.params.x)) {
        // Exclusive from the inclusive, which for a lane counting one is the
        // inclusive less one and for a lane counting more is the inclusive less
        // its own count. One expression covers both.
        uvec3 inclusive = scratch[t];
        uint opaque = keep.x != 0u ? inclusive.x - keep.x : CULLED;
        uint blend = keep.y != 0u ? inclusive.y - keep.y : CULLED;
        uint casting = keep.z != 0u ? inclusive.z - keep.z : CULLED;
        slots.slot[i] = (opaque << laneShift(LANE_OPAQUE))
            | (blend << laneShift(LANE_BLEND))
            | (casting << laneShift(LANE_CAST));
    }
    if (t == 255u) {
        uvec3 total = scratch[t];
        counts.count[gl_WorkGroupID.x] = total.x;
        blendCounts.count[gl_WorkGroupID.x] = total.y;
        castCounts.count[gl_WorkGroupID.x] = total.z;
    }
}
