#version 450
// Marks what survives the view test, sorts it into a lane, and prefixes it
// within its workgroup.
//
// Three passes rather than one atomic append, because an atomic gives no
// ordering: the compacted list comes out differently every frame, so
// overlapping geometry swaps which one wins and the scene shimmers. A scan is
// deterministic, so the same scene draws the same way every frame.
//
// Two lanes rather than one, because a blended instance must not reach the
// G-buffer: that pass writes with replace and has nowhere to put partial
// coverage, so an instance carrying an alpha below one leaves here for the
// forward pass instead. Both lanes are scanned in the same dispatch, over the
// one bound read the pass already pays for.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds {
    vec4 item[];   // xy centre, zw half extent
} bounds;

layout(set = 1, binding = 0) writeonly buffer Slots { uint slot[]; } slots;
layout(set = 1, binding = 1) writeonly buffer Counts { uint count[]; } counts;
layout(set = 1, binding = 2) writeonly buffer BlendCounts {
    uint count[];
} blendCounts;
layout(set = 2, binding = 0) uniform Cull {
    // World-space rectangle the camera can see: min xy, max xy.
    vec4 view;
    // Instance count, workgroup count, then the two fields the later passes
    // read: the destination list's capacity and which lane is being filled.
    vec4 params;
} cull;

#include "cull.glsl"

shared uint scratch[256];
shared uint blendScratch[256];

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;

    uint keep = 0u;
    uint keepBlend = 0u;
    if (i < uint(cull.params.x)) {
        vec4 box = bounds.item[i];
        // The sign of the first half extent says which lane, so the view test
        // works from the magnitude of both.
        vec2 extent = abs(box.zw);
        // Tested in world space now that a camera exists, so panning and
        // zooming change what survives rather than only what is drawn.
        bool outside = box.x + extent.x < cull.view.x || box.x - extent.x > cull.view.z ||
                       box.y + extent.y < cull.view.y || box.y - extent.y > cull.view.w;
        keep = outside ? 0u : 1u;
        // A survivor goes to one lane or the other and never to both, so the
        // two lists partition what the view kept rather than overlapping.
        if (keep == 1u && cullBlended(box)) {
            keep = 0u;
            keepBlend = 1u;
        }
        // An instance entirely outside its clip region is drawn and thrown
        // away a fragment at a time, which is correct and wasteful. Rejecting
        // it belongs here, as a second test against the region's rectangle
        // projected into the same space this one works in, and it needs the
        // region table and the instance's clip index reaching this pass. That
        // is a separate change and nothing here does it today.
    }

    // Inclusive scan across the workgroup, once per lane. Each survivor learns
    // how many survivors of its own lane precede it here, which is its offset
    // inside this block of that lane's list.
    scratch[t] = keep;
    blendScratch[t] = keepBlend;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint carried = 0u;
        uint carriedBlend = 0u;
        if (t >= stride) {
            carried = scratch[t - stride];
            carriedBlend = blendScratch[t - stride];
        }
        barrier();
        scratch[t] += carried;
        blendScratch[t] += carriedBlend;
        barrier();
    }

    if (i < uint(cull.params.x)) {
        uint opaque = keep == 1u ? scratch[t] - 1u : CULLED;
        uint blend = keepBlend == 1u ? blendScratch[t] - 1u : CULLED;
        slots.slot[i] = (opaque << LANE_OPAQUE) | (blend << LANE_BLEND);
    }
    if (t == 255u) {
        counts.count[gl_WorkGroupID.x] = scratch[t];
        blendCounts.count[gl_WorkGroupID.x] = blendScratch[t];
    }
}
