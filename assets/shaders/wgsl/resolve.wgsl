// What every fullscreen pass shares: the scene uniform, the graph's sampler,
// and the one triangle a resolve draws.
//
// One triangle rather than two, so no fragment sits on a diagonal seam and the
// vertex shader needs no buffer at all. A pass's declared inputs are bound as
// fragment textures in declaration order starting at binding one, with the
// graph's own nearest clamped sampler at binding zero: a graph target is read
// at the resolution it was written. The backend appends one
// `@group(1) @binding(n) var inputN` line per declared input, so a pass's
// module declares exactly the bindings its pipeline layout provides.

struct Scene {
    viewport: vec2<f32>,
    camera: vec2<f32>,
    zoom: f32,
    rotation: f32,
    reserved: vec2<f32>,
}

@group(0) @binding(0) var<uniform> scene: Scene;
@group(1) @binding(0) var passSampler: sampler;

struct FullscreenOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn fullscreenMain(@builtin(vertex_index) vertexIndex: u32) -> FullscreenOutput {
    // A triangle twice the size of the viewport, clipped down to it.
    let uv = vec2<f32>(f32((vertexIndex << 1u) & 2u), f32(vertexIndex & 2u));
    var output: FullscreenOutput;
    output.position = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
    output.uv = uv;
    return output;
}
