#version 450
// Replaces each workgroup survivor count with its stable destination base.
layout(local_size_x = 256) in;

layout(set = 1, binding = 0) buffer Counts { uint count[]; } counts;
layout(set = 2, binding = 0) uniform Cull {
    vec4 plane[6];
    vec4 params;
} cull;

#include "orderedscan.glsl"

void main() {
    scanOrderedBlockCounts(uint(cull.params.y));
}
