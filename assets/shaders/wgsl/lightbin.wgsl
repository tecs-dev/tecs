// Fills each tile with the lights that reach it.
//
// A thread per tile, walking the light buffer, rather than a thread per light
// scattering into the tiles it covers. The scatter does less arithmetic, and it
// needs an atomic to claim a slot and a second pass to zero the counts first.
// This does neither: a tile is written by the one thread that owns it, so a
// count is a local variable until it is stored and the list comes out in
// light-buffer order every time.
//
// That order is worth having rather than merely free. Accumulating a tile's
// lights is floating-point addition, which is not associative, so a list in a
// different order sums to a different last bit. Gathering means the question
// does not arise, and it costs nothing worth measuring: the work is tiles times
// lights, which at a thousand tiles and a full light buffer is a few hundred
// comparisons per thread against the millions of pixels it saves the lighting
// pass.
//
// Dispatched every frame, including a frame with no lights at all. It is the
// only thing that writes the counts, so skipping it would leave the previous
// frame's lists standing and light a scene by lights that are gone.

const LIGHT_TILES: u32 = 32u;
const LIGHT_TILE_SLOTS: u32 = 64u;

struct Light {
    position: vec4<f32>,
    color: vec4<f32>,
}

struct Bin {
    // World rectangle the grid covers: min xy, max xy. The same rectangle the
    // lighting pass maps its fragments into, taken from the same view and the
    // same target size, because a grid the two passes disagree about puts a
    // light in a tile nothing looks in.
    bounds: vec4<f32>,
    // x lights in the buffer.
    params: vec4<u32>,
}

@group(0) @binding(0) var<storage, read> lights: array<Light>;
@group(0) @binding(1) var<storage, read_write> tileCounts: array<u32>;
@group(0) @binding(2) var<storage, read_write> tileLights: array<u32>;
@group(0) @binding(3) var<uniform> bin: Bin;

@compute @workgroup_size(64)
fn binMain(@builtin(global_invocation_id) global: vec3<u32>) {
    let tile = global.x;
    if (tile >= LIGHT_TILES * LIGHT_TILES) {
        return;
    }

    let span = (bin.bounds.zw - bin.bounds.xy) / f32(LIGHT_TILES);
    let corner = bin.bounds.xy
        + span * vec2<f32>(f32(tile % LIGHT_TILES), f32(tile / LIGHT_TILES));

    let base = tile * LIGHT_TILE_SLOTS;
    var kept = 0u;
    let count = bin.params.x;
    for (var index = 0u; index < count; index = index + 1u) {
        if (kept >= LIGHT_TILE_SLOTS) {
            break;
        }
        let position = lights[index].position;
        // The light's own radius, not one widened by anything. A tile is being
        // asked what can illuminate it, and a light that reaches no pixel here
        // only takes a slot from one that does. Height is left out, which keeps
        // more than it must: a light standing above the plane reaches less far
        // across it than its radius, never further.
        let radius = max(position.w, 1.0);
        let nearest = clamp(position.xy, corner, corner + span);
        let offset = position.xy - nearest;
        if (dot(offset, offset) <= radius * radius) {
            tileLights[base + kept] = index;
            kept = kept + 1u;
        }
    }

    tileCounts[tile] = kept;
}
