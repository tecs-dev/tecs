#version 450
// Marks what survives the view test and prefixes it within its workgroup.
//
// Three passes rather than one atomic append, because an atomic gives no
// ordering: the compacted list comes out differently every frame, so
// overlapping geometry swaps which one wins and the scene shimmers. A scan is
// deterministic, so the same scene draws the same way every frame.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds {
    vec4 item[];   // xy centre, zw half extent
} bounds;

layout(set = 1, binding = 0) writeonly buffer Slots { uint slot[]; } slots;
layout(set = 1, binding = 1) writeonly buffer Counts { uint count[]; } counts;
layout(set = 2, binding = 0) uniform Cull {
    // World-space rectangle the camera can see: min xy, max xy.
    vec4 view;
    // Instance count, workgroup count.
    vec4 params;
} cull;

#include "cull.glsl"

shared uint scratch[256];

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;

    uint keep = 0u;
    if (i < uint(cull.params.x)) {
        vec4 box = bounds.item[i];
        // Tested in world space now that a camera exists, so panning and
        // zooming change what survives rather than only what is drawn.
        bool outside = box.x + box.z < cull.view.x || box.x - box.z > cull.view.z ||
                       box.y + box.w < cull.view.y || box.y - box.w > cull.view.w;
        keep = outside ? 0u : 1u;
        // An instance entirely outside its clip region is drawn and thrown
        // away a fragment at a time, which is correct and wasteful. Rejecting
        // it belongs here, as a second test against the region's rectangle
        // projected into the same space this one works in, and it needs the
        // region table and the instance's clip index reaching this pass. That
        // is a separate change and nothing here does it today.
    }

    // Inclusive scan across the workgroup. Each survivor learns how many
    // survivors precede it here, which is its offset inside this block.
    scratch[t] = keep;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint carried = 0u;
        if (t >= stride) { carried = scratch[t - stride]; }
        barrier();
        scratch[t] += carried;
        barrier();
    }

    if (i < uint(cull.params.x)) {
        slots.slot[i] = keep == 1u ? scratch[t] - 1u : CULLED;
    }
    if (t == 255u) {
        counts.count[gl_WorkGroupID.x] = scratch[t];
    }
}
