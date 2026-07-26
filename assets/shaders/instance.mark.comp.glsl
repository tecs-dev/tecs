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
layout(set = 2, binding = 0) uniform Cull { vec4 params; } cull;

#include "cull.glsl"

shared uint scratch[256];

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;

    uint keep = 0u;
    if (i < uint(cull.params.z)) {
        vec4 box = bounds.item[i];
        bool outside = box.x + box.z < 0.0 || box.x - box.z > cull.params.x ||
                       box.y + box.w < 0.0 || box.y - box.w > cull.params.y;
        keep = outside ? 0u : 1u;
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

    if (i < uint(cull.params.z)) {
        slots.slot[i] = keep == 1u ? scratch[t] - 1u : CULLED;
    }
    if (t == 255u) {
        counts.count[gl_WorkGroupID.x] = scratch[t];
    }
}
