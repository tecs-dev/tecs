#version 450
#pragma tecs variants MESH_ALPHA=1
// Marks visible mesh instances, assigns a stable rank within each workgroup,
// and clears the indirect destination while no later pass can race it.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds {
    vec4 sphere[];
} bounds;
#ifdef MESH_ALPHA
layout(set = 0, binding = 1) readonly buffer Instances { float value[]; } instances;
#endif

layout(set = 1, binding = 0) writeonly buffer Slots { uint slot[]; } slots;
layout(set = 1, binding = 1) writeonly buffer Counts { uint count[]; } counts;
layout(set = 1, binding = 2) writeonly buffer Commands { uint value[]; } commands;

layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    // Instance count, workgroup count, destination capacity, spare.
    vec4 params;
} cull;

shared uint scratch[256];

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;
    uint keep = 0u;
    if (i < uint(cull.params.x)) {
        vec4 sphere = bounds.sphere[i];
        keep = 1u;
        for (uint p = 0u; p < 6u; p++) {
            if (dot(cull.plane[p].xyz, sphere.xyz) + cull.plane[p].w < -sphere.w) {
                keep = 0u;
            }
        }
#ifdef MESH_ALPHA
        if (int(instances.value[i * 16u + 12u]) == 2) { keep = 0u; }
#endif

        // Every command is defined before compaction. This is a separate GPU
        // pass from compaction, so a later survivor cannot race this clear.
        uint command = i * 5u;
        commands.value[command] = 0u;
        commands.value[command + 1u] = 0u;
        commands.value[command + 2u] = 0u;
        commands.value[command + 3u] = 0u;
        commands.value[command + 4u] = 0u;
    }

    scratch[t] = keep;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint carried = t >= stride ? scratch[t - stride] : 0u;
        barrier();
        scratch[t] += carried;
        barrier();
    }

    if (i < uint(cull.params.x)) {
        slots.slot[i] = keep != 0u ? scratch[t] - 1u : 0xffffffffu;
    }
    if (t == 255u) {
        counts.count[gl_WorkGroupID.x] = scratch[t];
    }
}
