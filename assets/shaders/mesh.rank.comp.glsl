#version 450
// Gives each compacted blended command a stable rank inside one of 256 depth
// buckets. Empty command slots still write zero bucket counts, so shrinking a
// visible set needs no clearing pass or CPU-visible survivor count.
layout(local_size_x = 256) in;

layout(set = 0, binding = 0) readonly buffer Bounds { vec4 sphere[]; } bounds;
layout(set = 0, binding = 1) readonly buffer Commands { uint value[]; } commands;
layout(set = 1, binding = 0) writeonly buffer Buckets { uint value[]; } buckets;
layout(set = 1, binding = 1) writeonly buffer Ranks { uint value[]; } ranks;
layout(set = 1, binding = 2) writeonly buffer Counts { uint value[]; } counts;

layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
    mat4 viewProjection;
} cull;

shared uint bucketOf[256];

#include "bucketrank.glsl"

void main() {
    uint j = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;
    uint groups = uint(cull.params.y);
    uint bucket = RANK_NONE;
    uint command = j * 5u;
    if (j < uint(cull.params.x) && commands.value[command + 1u] != 0u) {
        uint instance = commands.value[command + 4u];
        vec4 clip = cull.viewProjection * vec4(bounds.sphere[instance].xyz, 1.0);
        float depth = clip.w != 0.0 ? clip.z / clip.w : 1.0;
        bucket = depthBucket(depth);
    }
    bucketOf[t] = bucket;
    barrier();

    uint rank = rankBefore(bucket, t);
    uint own = countBucket(t);
    counts.value[t * groups + gl_WorkGroupID.x] = own;
    if (bucket != RANK_NONE) {
        buckets.value[j] = bucket;
        ranks.value[j] = rank;
    }
}
