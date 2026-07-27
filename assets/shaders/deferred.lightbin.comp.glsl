#version 450
// Fills each tile with the lights that reach it.
//
// A thread per tile, walking the light buffer, rather than a thread per light
// scattering into the tiles it covers. The scatter does less arithmetic, and
// it needs an atomic to claim a slot and a second pass to zero the counts
// first. This does neither: a tile is written by the one thread that owns it,
// so a count is a local variable until it is stored and the list comes out in
// light-buffer order every time.
//
// That order is worth having rather than merely free. Accumulating a tile's
// lights is floating-point addition, which is not associative, so a list in a
// different order sums to a different last bit; the engine's rule is that a
// result nothing can observe an order in may use an atomic, and this one
// would have needed the argument. Gathering means the question does not
// arise. It also costs nothing worth measuring: the work is tiles times
// lights, which at a thousand tiles and a full light buffer is a few hundred
// comparisons per thread, against the millions of pixels this saves the
// lighting pass.
//
// Dispatched every frame, including a frame with no lights at all. It is the
// only thing that writes the counts, so skipping it would leave the previous
// frame's lists standing and light a scene by lights that are gone.

layout(local_size_x = 64) in;

struct Light {
    vec4 position;   // xy in world units, z height, w radius
    vec4 color;
};

layout(set = 0, binding = 0) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 1, binding = 0) writeonly buffer TileCounts {
    uint count[];
} tiles;

layout(set = 1, binding = 1) writeonly buffer TileLights {
    uint index[];
} tileLights;

layout(set = 2, binding = 0) uniform Bin {
    // World rectangle the grid covers: min xy, max xy. The same rectangle the
    // lighting pass maps its fragments into, taken from the same view and the
    // same target size, because a grid the two passes disagree about puts a
    // light in a tile nothing looks in.
    vec4 bounds;
    // Lights in the buffer.
    vec4 params;
} bin;

#include "lighting.glsl"

void main() {
    uint tile = gl_GlobalInvocationID.x;
    uint total = uint(LIGHT_TILES * LIGHT_TILES);
    if (tile >= total) { return; }

    vec2 span = (bin.bounds.zw - bin.bounds.xy) / float(LIGHT_TILES);
    vec2 corner = bin.bounds.xy
        + span * vec2(tile % uint(LIGHT_TILES), tile / uint(LIGHT_TILES));

    uint base = tile * uint(LIGHT_TILE_SLOTS);
    uint kept = 0u;
    int count = int(bin.params.x);
    for (int i = 0; i < count; i++) {
        if (kept >= uint(LIGHT_TILE_SLOTS)) { break; }

        vec4 position = lights.item[i].position;
        // The light's own radius, not one widened by anything. A tile is being
        // asked what can illuminate it, and a light that reaches no pixel here
        // only takes a slot from one that does. Height is left out, which
        // keeps more than it must: a light standing above the plane reaches
        // less far across it than its radius, never further.
        float radius = max(position.w, 1.0);
        vec2 nearest = clamp(position.xy, corner, corner + span);
        vec2 offset = position.xy - nearest;
        if (dot(offset, offset) <= radius * radius) {
            tileLights.index[base + kept] = uint(i);
            kept++;
        }
    }

    tiles.count[tile] = kept;
}
