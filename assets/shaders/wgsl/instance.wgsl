// The one draw every two-dimensional entity goes through.
//
// A vertex reads the instance the compaction chose rather than one the CPU
// bound, so the whole scene is a handful of indirect draws over one storage
// buffer. What a fragment looks like is a material's decision; this supplies
// the inputs and honors the coverage it gets back.
//
// The G-buffer entry point and the forward entry point differ in one input and
// one output: the forward pass blends, so it tells a material so and writes one
// color instead of four attachments.

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

struct Instance {
    // x, y, rotation, depth.
    position: vec4<f32>,
    // scaleX, scaleY, material parameter, caster height.
    scale: vec4<f32>,
    uvRect: vec4<f32>,
    color: vec4<f32>,
    material: u32,
    flags: u32,
    reserved0: u32,
    reserved1: u32,
}

struct BatchIndex {
    value: u32,
}

@group(0) @binding(0) var<uniform> scene: Scene;

@group(2) @binding(0) var<storage, read> instances: array<Instance>;
@group(2) @binding(1) var<storage, read> visible: array<u32>;
@group(2) @binding(2) var<storage, read> batchBase: array<u32>;
@group(2) @binding(3) var<uniform> batch: BatchIndex;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) local: vec2<f32>,
    @location(3) @interpolate(flat) material: u32,
    @location(4) @interpolate(flat) param: f32,
    // Cosine and sine of the instance's rotation, which turns a material's
    // normal out of the quad's space and into the world's.
    @location(5) @interpolate(flat) basis: vec2<f32>,
}

@vertex
fn vertexMain(@builtin(vertex_index) vertexIndex: u32, @builtin(instance_index) drawIndex: u32) -> VertexOutput {
    // The batch's base is where its lane's visible list holds this batch's
    // survivors. The compaction preserves packet order, so a single-lane batch
    // is one contiguous run and the draw's own instance index indexes into it.
    let source = visible[batchBase[batch.value] + drawIndex];
    let instance = instances[source];

    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(-0.5, 0.5),
        vec2<f32>(-0.5, 0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
    );
    let corner = corners[vertexIndex];
    let local = corner * instance.scale.xy;
    let sine = sin(instance.position.z);
    let cosine = cos(instance.position.z);
    let rotated = vec2<f32>(local.x * cosine - local.y * sine, local.x * sine + local.y * cosine);
    let world = instance.position.xy + rotated;

    // The world-to-clip matrix of `Camera2D.matrix`, applied without being
    // assembled. Y is negated once, here, because world y runs down; the
    // rotation is transposed so world offsets turn by minus the camera's
    // rotation and the negation above turns the scene back the other way.
    let sx = 2.0 * scene.zoom / scene.viewport.x;
    let sy = -2.0 * scene.zoom / scene.viewport.y;
    let c = cos(scene.rotation);
    let s = sin(scene.rotation);
    let offset = world - scene.camera;
    let clip = vec2<f32>(
        sx * c * offset.x + sx * s * offset.y,
        -sy * s * offset.x + sy * c * offset.y,
    );

    // The UV rectangle runs left to right and top to bottom, and the corner at
    // (-0.5, -0.5) is the top left one because world y runs down.
    let uvWeight = corner + vec2<f32>(0.5, 0.5);
    var output: VertexOutput;
    output.position = vec4<f32>(clip, instance.position.w, 1.0);
    output.color = instance.color;
    output.uv = mix(instance.uvRect.xy, instance.uvRect.zw, uvWeight);
    output.local = corner;
    output.material = instance.material;
    output.param = instance.scale.z;
    output.basis = vec2<f32>(cosine, sine);
    return output;
}

fn shade(input: VertexOutput, blended: bool) -> MaterialOutput {
    var frag: MaterialInput;
    frag.local = input.local;
    frag.uv = input.uv;
    frag.color = input.color;
    frag.param = input.param;
    frag.blended = blended;
    return materialDispatch(input.material, frag);
}

struct GBuffer {
    @location(0) albedo: vec4<f32>,
    @location(1) normal: vec4<f32>,
    @location(2) orm: vec4<f32>,
    @location(3) emission: vec4<f32>,
}

@fragment
fn geometryMain(input: VertexOutput) -> GBuffer {
    // This pass writes with replace, so a material that has an edge to resolve
    // has to resolve it by discarding.
    let shaded = shade(input, false);

    // Coverage decides membership, not opacity. A partly covered edge fragment
    // would overwrite what is behind it instead of blending into it, so smooth
    // edges belong in the forward lane.
    if (shaded.coverage <= 0.0) {
        discard;
    }

    // Out of the quad's space and into the world, which is where the lighting
    // pass works. Only the two in-plane axes turn: the quad lies in the XY
    // plane, so its perpendicular is unaffected by anything a 2x2 can do, and
    // the basis is a rotation, so what arrives unit length leaves unit length.
    let c = input.basis.x;
    let s = input.basis.y;
    let faced = vec3<f32>(
        shaded.normal.x * c - shaded.normal.y * s,
        shaded.normal.x * s + shaded.normal.y * c,
        shaded.normal.z,
    );

    var output: GBuffer;
    output.albedo = shaded.albedo;
    // Biased into unsigned range, since the attachment has no signed
    // representation, and the lighting pass undoes exactly this. The alpha
    // carries whether the fragment wants lighting.
    output.normal = vec4<f32>(faced * 0.5 + 0.5, shaded.lit);
    // Occlusion, roughness and metallic stay in their own target so the
    // lighting pass can use them without taking channels from the albedo or
    // normal. Alpha is reserved and carried unchanged.
    output.orm = shaded.orm;
    // What the surface gives off, kept out of the albedo so the resolve can add
    // it after the lighting rather than multiply it by it.
    output.emission = shaded.emission;
    return output;
}

@fragment
fn forwardMain(input: VertexOutput) -> @location(0) vec4<f32> {
    let shaded = shade(input, true);
    if (shaded.coverage <= 0.0) {
        discard;
    }

    // An instance in the blended lane adds its own emission to its own color
    // and reaches the emission attachment not at all, because this pass runs
    // after the G-buffer has been resolved. It therefore glows, and it does not
    // reach a later pass that reads the attachment.
    let emitted = shaded.emission.rgb * shaded.emission.a;
    return vec4<f32>(shaded.albedo.rgb + emitted, shaded.albedo.a);
}
