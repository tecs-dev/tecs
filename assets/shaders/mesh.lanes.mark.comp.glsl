#version 450
#pragma tecs variants MESH_DOUBLE_SIDED=1
// Marks opaque and blended mesh commands in one frustum walk. This shader is
// loaded only by a mesh domain that opted into transparency; opaque-only
// domains keep the smaller mesh.mark pipeline and its three-pass chain.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds { vec4 sphere[]; } bounds;
layout(set = 0, binding = 1) readonly buffer Instances { float value[]; } instances;

layout(set = 1, binding = 0) writeonly buffer OpaqueSlots { uint slot[]; } opaqueSlots;
layout(set = 1, binding = 1) writeonly buffer OpaqueCounts { uint count[]; } opaqueCounts;
layout(set = 1, binding = 2) writeonly buffer OpaqueCommands { uint value[]; } opaqueCommands;
layout(set = 1, binding = 3) writeonly buffer BlendSlots { uint slot[]; } blendSlots;
layout(set = 1, binding = 4) writeonly buffer BlendCounts { uint count[]; } blendCounts;
layout(set = 1, binding = 5) writeonly buffer BlendCommands { uint value[]; } blendCommands;
layout(set = 1, binding = 6) writeonly buffer SortedCommands { uint value[]; } sortedCommands;

layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
    mat4 viewProjection;
} cull;

const int ALPHA_BLEND = 2;
shared uint opaqueScratch[256];
shared uint blendScratch[256];

void clearCommand(uint i) {
    uint command = i * 5u;
    for (uint lane = 0u; lane < 5u; lane++) {
        opaqueCommands.value[command + lane] = 0u;
        blendCommands.value[command + lane] = 0u;
        sortedCommands.value[command + lane] = 0u;
    }
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;
    uint visible = 0u;
    uint blended = 0u;
    if (i < uint(cull.params.x)) {
        vec4 sphere = bounds.sphere[i];
        visible = 1u;
        for (uint p = 0u; p < 6u; p++) {
            if (dot(cull.plane[p].xyz, sphere.xyz) + cull.plane[p].w < -sphere.w) {
                visible = 0u;
            }
        }
        int lane = int(instances.value[i * 16u + 12u]);
        blended = (lane & 3) == ALPHA_BLEND ? visible : 0u;
#ifdef MESH_DOUBLE_SIDED
        if ((lane & 4) != 0) { visible = blended; }
#endif
        clearCommand(i);
    }

    opaqueScratch[t] = visible - blended;
    blendScratch[t] = blended;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint opaqueCarried = t >= stride ? opaqueScratch[t - stride] : 0u;
        uint blendCarried = t >= stride ? blendScratch[t - stride] : 0u;
        barrier();
        opaqueScratch[t] += opaqueCarried;
        blendScratch[t] += blendCarried;
        barrier();
    }

    if (i < uint(cull.params.x)) {
        opaqueSlots.slot[i] = visible != blended ? opaqueScratch[t] - 1u : 0xffffffffu;
        blendSlots.slot[i] = blended != 0u ? blendScratch[t] - 1u : 0xffffffffu;
    }
    if (t == 255u) {
        opaqueCounts.count[gl_WorkGroupID.x] = opaqueScratch[t];
        blendCounts.count[gl_WorkGroupID.x] = blendScratch[t];
    }
}
