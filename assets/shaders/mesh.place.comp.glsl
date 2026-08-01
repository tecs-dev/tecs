#version 450
// Copies complete indexed commands into their depth-sorted destinations.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Commands { uint value[]; } commands;
layout(set = 0, binding = 1) readonly buffer Buckets { uint value[]; } buckets;
layout(set = 0, binding = 2) readonly buffer Ranks { uint value[]; } ranks;
layout(set = 0, binding = 3) readonly buffer Bases { uint value[]; } bases;
layout(set = 1, binding = 0) writeonly buffer Sorted { uint value[]; } sorted;

layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
    mat4 viewProjection;
} cull;

void main() {
    uint j = gl_GlobalInvocationID.x;
    if (j >= uint(cull.params.x)) { return; }
    uint source = j * 5u;
    if (commands.value[source + 1u] == 0u) { return; }
    uint groups = uint(cull.params.y);
    uint at = bases.value[buckets.value[j] * groups + gl_WorkGroupID.x] + ranks.value[j];
    uint destination = at * 5u;
    for (uint lane = 0u; lane < 5u; lane++) {
        sorted.value[destination + lane] = commands.value[source + lane];
    }
}
