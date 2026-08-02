// Replaces stable per-workgroup counts with their exclusive destination bases.
// The caller declares counts.count[] and dispatches exactly one 256-lane group.
shared uint orderedScanPartial[256];

uint scanOrderedBlockCounts(uint blocks) {
    uint lane = gl_LocalInvocationID.x;
    uint span = (blocks + 255u) / 256u;
    uint begin = lane * span;
    uint end = min(begin + span, blocks);

    uint sum = 0u;
    for (uint index = begin; index < end; index++) {
        sum += counts.count[index];
    }

    orderedScanPartial[lane] = sum;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint carried = 0u;
        if (lane >= stride) {
            carried = orderedScanPartial[lane - stride];
        }
        barrier();
        orderedScanPartial[lane] += carried;
        barrier();
    }

    uint base = orderedScanPartial[lane] - sum;
    for (uint index = begin; index < end; index++) {
        uint count = counts.count[index];
        counts.count[index] = base;
        base += count;
    }
    return orderedScanPartial[255];
}
