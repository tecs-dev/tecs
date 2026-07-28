#version 450
// Writes the forward list out in depth order, from the bases the bucket scan
// produced and the rank each entry was given inside its bucket.
//
// The counterpart of `instance.compact`, and separate from it because the
// offset an entry lands at is looked up by its own bucket rather than by its
// workgroup: the bases table has a row per bucket and this pass is the only
// one that knows which row an entry belongs to.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Visible { uint index[]; } visible;
layout(set = 0, binding = 1) readonly buffer Buckets { uint value[]; } buckets;
layout(set = 0, binding = 2) readonly buffer Ranks { uint value[]; } ranks;
layout(set = 0, binding = 3) readonly buffer Bases { uint base[]; } bases;
layout(set = 0, binding = 4) readonly buffer DrawArgs { uint value[]; } args;

layout(set = 1, binding = 0) writeonly buffer Sorted { uint index[]; } sorted;

layout(set = 2, binding = 0) uniform Cull {
    vec4 view;
    // y is the block count the bases table is laid out against, and it has to
    // be the one the ranking pass wrote against or an entry lands in another
    // bucket's run.
    vec4 params;
    vec4 extra;
} cull;

void main() {
    uint j = gl_GlobalInvocationID.x;
    if (j >= args.value[1]) { return; }
    uint at = bases.base[buckets.value[j] * uint(cull.params.y) + gl_WorkGroupID.x] + ranks.value[j];
    sorted.index[at] = visible.index[j];
}
