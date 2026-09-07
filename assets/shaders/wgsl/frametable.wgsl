// Original millisecond directory lookup, shared by geometry and shadow passes.
@group(1) @binding(6) var<storage, read> frameTable: array<f32>;
fn animatedInstance(source: Instance) -> Instance {
    if (source.uvRect.x >= 0.0 || (source.flags & 16u) != 0u) { return source; }
    let id = u32(-source.uvRect.x + 0.5);
    if (id == 0u || id > u32(frameTable[0])) { return source; }
    let directory = 1u + (id - 1u) * 4u;
    let entryBase = u32(frameTable[directory]);
    let tickBase = u32(frameTable[directory + 1u]);
    let count = frameTable[directory + 2u];
    var tick = source.uvRect.y;
    if (source.uvRect.z > 0.0) { tick = (scene.reserved.x - tick) * source.uvRect.z; }
    if (source.uvRect.w != 0.0) { tick = tick - floor(tick / count) * count; }
    tick = clamp(floor(tick), 0.0, count - 1.0);
    let at = entryBase + u32(frameTable[tickBase + u32(tick)]) * 8u;
    var result = source;
    result.uvRect = vec4<f32>(frameTable[at], frameTable[at+1u], frameTable[at+2u], frameTable[at+3u]);
    let offset = -vec2<f32>(frameTable[at+5u], frameTable[at+6u]) * source.scale.xy;
    let c = cos(source.position.z); let s = sin(source.position.z);
    result.position.x += offset.x * c - offset.y * s;
    result.position.y += offset.x * s + offset.y * c;
    return result;
}
