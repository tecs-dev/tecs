#version 450
// Replaces each workgroup survivor count with its stable destination base.
layout(local_size_x = 256) in;

layout(set = 1, binding = 0) buffer Counts { uint count[]; } counts;
layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
} cull;

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
        uint carried = t >= stride ? partial[t - stride] : 0u;
        barrier();
        partial[t] += carried;
        barrier();
    }

    uint base = partial[t] - sum;
    for (uint i = begin; i < end; i++) {
        uint block = counts.count[i];
        counts.count[i] = base;
        base += block;
    }
}
