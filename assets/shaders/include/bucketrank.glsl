// Shared stable rank over one 256-entry workgroup. The including shader owns
// `bucketOf`, because shared storage must remain visible to its entry point.
const uint RANK_BUCKETS = 256u;
const uint RANK_NONE = 0xffffffffu;

uint depthBucket(float depth) {
    return uint(clamp(1.0 - depth, 0.0, 0.999999) * float(RANK_BUCKETS));
}

uint rankBefore(uint bucket, uint thread) {
    uint rank = 0u;
    for (uint index = 0u; index < thread; index++) {
        if (bucketOf[index] == bucket) { rank++; }
    }
    return rank;
}

uint countBucket(uint bucket) {
    uint count = 0u;
    for (uint index = 0u; index < RANK_BUCKETS; index++) {
        if (bucketOf[index] == bucket) { count++; }
    }
    return count;
}
