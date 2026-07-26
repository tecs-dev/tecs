#version 450
// Turns per-block survivor counts into per-block base offsets.
//
// One workgroup, so the scan is over blocks rather than entities and stays a
// single dispatch however large the world is. Each thread folds a contiguous
// span serially, the folded totals are scanned, and the span is rewritten in
// place as running bases.
layout(local_size_x = 256) in;

layout(set = 1, binding = 0) buffer Counts { uint count[]; } counts;
layout(set = 1, binding = 1) buffer DrawArgs { uint value[]; } args;
layout(set = 2, binding = 0) uniform Cull { vec4 view; vec4 params; } cull;

shared uint partial[256];

void main() {
    uint t = gl_LocalInvocationID.x;
    uint blocks = uint(cull.params.y);
    uint span = (blocks + 255u) / 256u;
    uint begin = t * span;
    uint end = min(begin + span, blocks);

    uint sum = 0u;
    for (uint i = begin; i < end; i++) { sum += counts.count[i]; }

    partial[t] = sum;
    barrier();
    for (uint stride = 1u; stride < 256u; stride <<= 1) {
        uint carried = 0u;
        if (t >= stride) { carried = partial[t - stride]; }
        barrier();
        partial[t] += carried;
        barrier();
    }

    // Exclusive: where this thread's span starts in the compacted list.
    uint base = partial[t] - sum;
    for (uint i = begin; i < end; i++) {
        uint block = counts.count[i];
        counts.count[i] = base;
        base += block;
    }

    if (t == 255u) {
        // The draw's instance count, which the CPU never reads back.
        args.value[1] = partial[255];
    }
}
