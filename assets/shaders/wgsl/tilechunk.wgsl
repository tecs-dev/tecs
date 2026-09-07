// One compact grid per chunk; the vertex stage expands only visible chunks.
struct TileChunk {
    atlas: array<f32, 12>,
    cells: array<u32, 256>,
}
@group(1) @binding(5) var<storage, read> tileChunks: array<TileChunk>;

fn tileInstance(source: Instance, cell: u32) -> Instance {
    if ((source.flags & 16u) == 0u) { return source; }
    let slot = u32(source.uvRect.x);
    let encoded = tileChunks[slot].cells[cell];
    var result = source;
    if ((encoded & 0x1fffffffu) == 0u) {
        result.scale.x = 0.0;
        result.scale.y = 0.0;
        return result;
    }
    let w = tileChunks[slot].atlas[0];
    let h = tileChunks[slot].atlas[1];
    let columns = u32(tileChunks[slot].atlas[2]);
    let spacing = tileChunks[slot].atlas[3];
    let margin = tileChunks[slot].atlas[4];
    let cw = tileChunks[slot].atlas[5];
    let ch = tileChunks[slot].atlas[6];
    let dx = f32(cell % 16u) * cw + w * 0.5 + tileChunks[slot].atlas[7];
    let dy = f32(cell / 16u + 1u) * ch - h * 0.5 + tileChunks[slot].atlas[8];
    let p = vec2<f32>(dx, dy) * source.scale.xy;
    let c = cos(source.position.z);
    let s = sin(source.position.z);
    result.position.x += p.x * c - p.y * s;
    result.position.y += p.x * s + p.y * c;
    result.scale.x *= w;
    result.scale.y *= h;
    let flipH = (encoded & 0x80000000u) != 0u;
    let flipV = (encoded & 0x40000000u) != 0u;
    if ((encoded & 0x20000000u) != 0u) {
        result.position.z += 1.5707963267948966;
        result.scale.y *= select(-1.0, 1.0, flipH);
        result.scale.x *= select(1.0, -1.0, flipV);
    } else {
        result.scale.x *= select(1.0, -1.0, flipH);
        result.scale.y *= select(1.0, -1.0, flipV);
    }
    let id = (encoded & 0x1fffffffu) - 1u;
    let uv = vec2<f32>(margin) + vec2<f32>(f32(id % columns), f32(id / columns)) * (vec2<f32>(w, h) + vec2<f32>(spacing));
    let imageSize = vec2<f32>(tileChunks[slot].atlas[9], tileChunks[slot].atlas[10]);
    result.uvRect = vec4<f32>(uv / imageSize, (uv + vec2<f32>(w, h)) / imageSize);
    return result;
}
