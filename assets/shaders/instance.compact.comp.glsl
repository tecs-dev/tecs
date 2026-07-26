#version 450
// Writes each survivor at the offset the scan assigned it.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Slots { uint slot[]; } slots;
layout(set = 0, binding = 1) readonly buffer Bases { uint base[]; } bases;
layout(set = 1, binding = 0) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Cull { vec4 params; } cull;

#include "cull.glsl"

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.z)) { return; }
    uint offset = slots.slot[i];
    if (offset == CULLED) { return; }
    visible.index[bases.base[gl_WorkGroupID.x] + offset] = i;
}
