#version 450
// Compacts indexed commands without changing their original instance index.
// Geometry may vary per command, so the command itself, not just an instance
// index, is the compacted unit.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Slots { uint slot[]; } slots;
layout(set = 0, binding = 1) readonly buffer Bases { uint base[]; } bases;
layout(set = 0, binding = 2) readonly buffer SourceCommands { uint value[]; } sourceCommands;
layout(set = 1, binding = 0) writeonly buffer VisibleCommands { uint value[]; } visibleCommands;
layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
} cull;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.x)) { return; }
    uint localRank = slots.slot[i];
    if (localRank == 0xffffffffu) { return; }
    uint at = bases.base[gl_WorkGroupID.x] + localRank;
    if (at >= uint(cull.params.z)) { return; }

    uint source = i * 5u;
    uint destination = at * 5u;
    visibleCommands.value[destination] = sourceCommands.value[source];
    visibleCommands.value[destination + 1u] = sourceCommands.value[source + 1u];
    visibleCommands.value[destination + 2u] = sourceCommands.value[source + 2u];
    visibleCommands.value[destination + 3u] = sourceCommands.value[source + 3u];
    visibleCommands.value[destination + 4u] = sourceCommands.value[source + 4u];
}
