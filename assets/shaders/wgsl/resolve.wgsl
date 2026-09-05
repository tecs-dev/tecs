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

// The scene uniform every pass reads, at group zero binding zero.
//
// One buffer for the whole frame, so a pass that wants the camera, the ambient
// term, the shadow tuning or the bloom tuning binds nothing of its own. The
// same thirty-two floats are declared in `instance.wgsl`, `resolve.wgsl` and
// `cast.wgsl`; WGSL has no include, so the three are one layout written three
// times and they only work while they agree.
struct Scene {
    // Render target size in pixels.
    viewport: vec2<f32>,
    // View center in world units.
    camera: vec2<f32>,
    zoom: f32,
    rotation: f32,
    reserved: vec2<f32>,
    // rgb the light every surface receives before any light entity, and a one
    // when the shadow lane ran this frame.
    ambient: vec4<f32>,
    // World rectangle the light tile grid covers: min xy then max xy. The same
    // rectangle the binning pass used, because a grid the two disagree about
    // puts a light in a tile nothing looks in.
    bounds: vec4<f32>,
    // World to occluder-mask UV, as the four components of a 2x2 in row order.
    // The mask's projection is the camera's own widened by the shadow margin,
    // so it is orthographic too and inverts to exactly this. At up to `steps`
    // samples per light per pixel that is two multiply-adds rather than a 4x4
    // by a vec4 on every one of them.
    maskXform: vec4<f32>,
    // xy the offset that goes with it, z how many steps a march at full
    // attenuation takes, w the world height a full-height occluder stands.
    maskParams: vec4<f32>,
    // x how dark a drop shadow is at full weight, y the longest one may be in
    // world units, z the shadow margin in world units, w the light count.
    shadowParams: vec4<f32>,
    // x threshold, y soft knee, z intensity, w one when bloom ran this frame.
    bloom: vec4<f32>,
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
