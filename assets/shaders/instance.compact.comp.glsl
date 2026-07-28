#version 450
// Writes each survivor of one lane at the offset the scan assigned it.
//
// Run once per lane, over the same slots the mark pass packed both into. Which
// lane is being filled arrives in the uniform rather than being compiled in,
// so the opaque list and the forward list come out of one shader and cannot
// drift apart.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Slots { uint slot[]; } slots;
layout(set = 0, binding = 1) readonly buffer Bases { uint base[]; } bases;
layout(set = 1, binding = 0) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Cull {
    vec4 view;
    // x instance count, y workgroup count, z the destination list's capacity,
    // w which lane's rank to read out of a slot.
    vec4 params;
} cull;

#include "cull.glsl"

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.x)) { return; }
    uint offset = (slots.slot[i] >> uint(cull.params.w)) & LANE_MASK;
    if (offset == CULLED) { return; }
    uint at = bases.base[gl_WorkGroupID.x] + offset;
    // Past the end is dropped rather than wrapped. The scan held the draw to
    // the same ceiling, so what is dropped here is what the draw already
    // stopped short of, and both are the survivors earliest in the buffer.
    if (at < uint(cull.params.z)) { visible.index[at] = i; }
}
