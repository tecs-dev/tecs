#version 450
// Buckets the forward list by depth and ranks each entry inside its bucket.
//
// Blending is not commutative, so the forward pass has to draw back to front
// while the compaction that produced its list is ordered by instance index,
// which is where the extractor put a row and not where the scene put it. This
// is the sort that turns one into the other, and it is a counting sort for the
// same reason the compaction is a scan rather than an atomic append: a counting
// sort is stable, so the same scene comes out in the same order every frame.
//
// It runs over the compacted forward list rather than over the world. The
// counts a bucketed scan needs are one per bucket per block, and a block per
// 256 instances of the whole world would be a table nobody could afford to
// scan; over a list that has already been compacted and capped it is a fixed
// quarter of a megabyte.
//
// One bucket per thread, which is what makes the pass affordable and what fixes
// the bucket count at the workgroup size: every thread counts its own bucket
// across the block, so every entry of this block's column is written whether
// anything landed in it or not, and no clearing pass is needed.
layout(local_size_x = 256) in;

const uint BUCKETS = 256u;

// A thread with no entry. No thread index equals it, so it counts towards no
// bucket and contributes nothing to any rank.
const uint BUCKET_NONE = 0xFFFFFFFFu;

struct Instance {
    vec4 xform;   // rotation, scaleX, scaleY, depth
    vec4 origin;
    vec4 color;
    vec4 uvRect;
};

layout(set = 0, binding = 0) readonly buffer Instances {
    Instance item[];
} instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;
layout(set = 0, binding = 2) readonly buffer DrawArgs { uint value[]; } args;

layout(set = 1, binding = 0) writeonly buffer Buckets { uint value[]; } buckets;
layout(set = 1, binding = 1) writeonly buffer Ranks { uint value[]; } ranks;
layout(set = 1, binding = 2) writeonly buffer Counts { uint count[]; } counts;

layout(set = 2, binding = 0) uniform Cull {
    vec4 view;
    // y is the block count the counts table is laid out against. The entry
    // count is not here: what bounds this pass is the number the scan wrote
    // into the draw arguments, which the CPU never learns.
    vec4 params;
} cull;

shared uint bucketOf[256];

void main() {
    uint j = gl_GlobalInvocationID.x;
    uint t = gl_LocalInvocationID.x;
    uint blocks = uint(cull.params.y);
    uint total = args.value[1];

    uint bucket = BUCKET_NONE;
    if (j < total) {
        // Depth runs zero to one with zero nearest, so the farthest instance
        // has the largest depth and has to draw first. One minus it is the
        // key, quantised to the bucket count: two instances closer together
        // than a bucket keep the order the compaction gave them, which is the
        // same tie-break the depth test already gives opaque geometry.
        float depth = instances.item[visible.index[j]].xform.w;
        bucket = uint(clamp(1.0 - depth, 0.0, 0.999999) * float(BUCKETS));
    }
    bucketOf[t] = bucket;
    barrier();

    // How many earlier entries of this block share the bucket, which is this
    // entry's offset within the block's run of it.
    uint rank = 0u;
    for (uint k = 0u; k < t; k++) {
        if (bucketOf[k] == bucket) { rank++; }
    }

    // Bucket major, so the scan over this table walks every block of one
    // bucket before the first block of the next and the bases it produces put
    // the far buckets ahead of the near ones.
    uint own = 0u;
    for (uint k = 0u; k < BUCKETS; k++) {
        if (bucketOf[k] == t) { own++; }
    }
    counts.count[t * blocks + gl_WorkGroupID.x] = own;

    if (j < total) {
        buckets.value[j] = bucket;
        ranks.value[j] = rank;
    }
}
