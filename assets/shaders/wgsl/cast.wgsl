// The three shadow draws, and one shader for all of them.
//
// All three place a quad from the same instance record against the same cast
// list and differ only in where they put it and what they reject. The occluder
// mask draws a caster's own silhouette; the drop-shadow pass draws it again
// stretched away from each light that reaches it; the stamp draws it once more
// at its own transform, to put the caster back on top of the shadow it threw
// across its own feet. Splitting them into three shaders would mean three copies
// of the placement.
//
// What is deliberately not here is the layer table. An occluder blocks light in
// the world and a shadow lands on the ground in the world, so both are placed by
// the camera and neither takes a layer's parallax, screen-space placement or
// ignored zoom. A caster on a screen-space layer casts nothing, which is what it
// should do: there is no ground under the heads-up display.
//
// Coverage comes from the material dispatch rather than from texture alpha,
// which is why a caster needs no alpha threshold of its own: the threshold a
// sprite would have applied is the coverage its material already applied, and a
// circle, a rounded box or a glyph casts for nothing.

// The scene uniform every pass reads, at group zero binding zero.
//
// The same thirty-two floats are declared in `instance.wgsl`, `resolve.wgsl` and
// `cast.wgsl`; WGSL has no include, so the three are one layout written three
// times and they only work while they agree.
struct Scene {
    viewport: vec2<f32>,
    camera: vec2<f32>,
    zoom: f32,
    rotation: f32,
    reserved: vec2<f32>,
    ambient: vec4<f32>,
    bounds: vec4<f32>,
    maskXform: vec4<f32>,
    maskParams: vec4<f32>,
    shadowParams: vec4<f32>,
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

struct Light {
    position: vec4<f32>,
    color: vec4<f32>,
}

struct BatchIndex {
    value: u32,
}

struct CastMode {
    value: u32,
}

@group(0) @binding(0) var<uniform> scene: Scene;

@group(2) @binding(0) var<storage, read> instances: array<Instance>;
@group(2) @binding(1) var<storage, read> castList: array<u32>;
@group(2) @binding(2) var<storage, read> castBase: array<u32>;
@group(2) @binding(3) var<uniform> batch: BatchIndex;
@group(2) @binding(4) var<storage, read> lights: array<Light>;
@group(2) @binding(5) var<uniform> castMode: CastMode;

// Entries the shadow lane emits per caster, and the packing of one. The same
// three constants live in `cull.wgsl`, which fills the list this reads.
const CAST_FANOUT: u32 = 4u;
const CAST_LIGHT_BITS: u32 = 9u;
const CAST_LIGHT_MASK: u32 = 0x1ffu;
// An entry that draws nothing, which a caster with fewer lights than the fan-out
// fills the rest of its run with.
const CAST_EMPTY: u32 = 0x1feu;
// An entry that names the caster rather than a light: an occluder's silhouette,
// and the copy of a drop-shadow caster that stamps it back out of its own
// shadow. Both draw the source instance's own transform.
const CAST_NONE: u32 = 0x1ffu;

// Which draw is running. One pipeline per blend mode and one dynamic uniform
// offset per draw, so this selects rather than being compiled in.
const CAST_MODE_MASK: u32 = 0u;
const CAST_MODE_SHADOW: u32 = 1u;
const CAST_MODE_STAMP: u32 = 2u;

// Below this a light throws no copy at all. The faintest shadow a viewer can
// pick out is well above it.
const CAST_MIN_WEIGHT: f32 = 0.05;

struct CastOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) local: vec2<f32>,
    @location(3) @interpolate(flat) material: u32,
    @location(4) @interpolate(flat) param: f32,
    // What the fragment writes where it is covered: the caster's height for the
    // mask, and one less the shadow's darkness for the other two. Flat, because
    // it is the instance's and the light's rather than the fragment's.
    @location(5) @interpolate(flat) value: f32,
}

// Off the front of the near plane, and the same point for all six corners, so
// the primitive has no area at all rather than a small one somewhere.
fn reject() -> CastOutput {
    var output: CastOutput;
    output.position = vec4<f32>(2.0, 2.0, 2.0, 1.0);
    output.color = vec4<f32>(0.0);
    output.uv = vec2<f32>(0.0);
    output.local = vec2<f32>(0.0);
    output.material = 0u;
    output.param = 0.0;
    output.value = 0.0;
    return output;
}

// The world-to-clip mapping `instance.wgsl` applies, written out the same way.
fn cameraClip(world: vec2<f32>) -> vec2<f32> {
    let sx = 2.0 * scene.zoom / scene.viewport.x;
    let sy = -2.0 * scene.zoom / scene.viewport.y;
    let c = cos(scene.rotation);
    let s = sin(scene.rotation);
    let offset = world - scene.camera;
    return vec2<f32>(
        sx * c * offset.x + sx * s * offset.y,
        -sy * s * offset.x + sy * c * offset.y,
    );
}

// The camera's own projection widened by the shadow margin, which is exactly the
// transform the lighting pass inverts to find a mask texel. UV runs down from
// the top left and clip y runs up, so the y is negated once here.
fn maskClip(world: vec2<f32>) -> vec2<f32> {
    let uv = vec2<f32>(dot(scene.maskXform.xy, world), dot(scene.maskXform.zw, world))
        + scene.maskParams.xy;
    return vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
}

// How much of a light reaches a point, which decides both which lights a caster
// keeps and how dark the copy each one throws is.
//
// The same falloff the resolve applies, including the light's height as the
// third axis, so a shadow fades out exactly where the light that cast it does.
// `cull.wgsl` selects by this and this darkens by it, and the two have to agree:
// a shadow selected as the strongest and then drawn at another weight is a
// shadow that pops when an unrelated light moves.
fn castWeight(toLight: vec3<f32>, radius: f32, intensity: f32) -> f32 {
    let reach = max(radius, 1.0);
    let attenuation = clamp(1.0 - length(toLight) / reach, 0.0, 1.0);
    return intensity * attenuation * attenuation;
}

@vertex
fn castVertexMain(
    @builtin(vertex_index) vertexIndex: u32,
    @builtin(instance_index) drawIndex: u32,
) -> CastOutput {
    let entry = castList[castBase[batch.value] + drawIndex];
    let light = entry & CAST_LIGHT_MASK;
    // Every caster's run is the same length, so which copy of it this is comes
    // from the position rather than from a field.
    let rank = drawIndex % CAST_FANOUT;
    let mode = castMode.value;

    // An occluder's entries say so by naming no light, which is also what tells
    // the two drop-shadow draws to leave it alone: it darkens nothing, it
    // blocks.
    let named = light == CAST_NONE;
    if (mode == CAST_MODE_MASK) {
        if (!named) {
            return reject();
        }
    } else if (mode == CAST_MODE_STAMP) {
        if (named || rank != 0u) {
            return reject();
        }
    } else {
        if (light >= CAST_EMPTY) {
            return reject();
        }
    }

    let instance = instances[entry >> CAST_LIGHT_BITS];
    let angle = instance.position.z;
    let scaleX = instance.scale.x;
    let scaleY = instance.scale.y;
    let c = cos(angle);
    let s = sin(angle);

    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(-0.5, 0.5),
        vec2<f32>(-0.5, 0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
    );
    let corner = corners[vertexIndex];
    let height = instance.scale.w;

    var world: vec2<f32>;
    var value: f32;
    var clip: vec2<f32>;
    if (mode == CAST_MODE_SHADOW) {
        // Where the caster meets the ground, which is the bottom edge of its
        // quad: a shadow is thrown from a thing's feet and not from its middle.
        let down = vec2<f32>(0.0, 0.5 * scaleY);
        let foot = instance.position.xy + vec2<f32>(down.x * c - down.y * s, down.x * s + down.y * c);
        let lit = lights[light];
        let toLight = lit.position.xy - foot;
        let ground = length(toLight);
        // A light directly over the caster throws no shadow in any direction,
        // and there is no direction to throw it in either.
        if (ground < 1e-4) {
            return reject();
        }
        let away = -toLight / ground;

        // How tall the caster stands, in world units. Where the tip lands is
        // similar triangles and nothing else: the light at height Lz over a
        // caster of height h throws the caster's top to h / (Lz - h) of the
        // horizontal distance beyond its feet. A light at or below the caster's
        // own height would throw it to infinity, so the length is bounded rather
        // than the formula being guarded twice.
        let tall = height * abs(scaleY);
        let reach = clamp(
            ground * tall / max(lit.position.z - tall, 1e-3),
            0.0,
            scene.shadowParams.y,
        );

        // The silhouette laid down: its bottom edge stays at the feet and its
        // top edge goes to the tip, so the whole shape stretches along the
        // ground rather than sliding down it.
        let across = vec2<f32>(-away.y, away.x);
        world = foot + across * (corner.x * scaleX) + away * ((0.5 - corner.y) * reach);
        let weight = castWeight(vec3<f32>(toLight, lit.position.z), lit.position.w, lit.color.a);
        value = 1.0 - clamp(scene.shadowParams.x * weight, 0.0, 1.0);
        clip = cameraClip(world);
    } else {
        let local = corner * vec2<f32>(scaleX, scaleY);
        world = instance.position.xy + vec2<f32>(local.x * c - local.y * s, local.x * s + local.y * c);
        // The mask carries the height the raymarch measures a shadow's reach
        // against. The stamp carries no darkness at all, which is the whole of
        // what it is for: it puts the caster back at full brightness over the
        // shadow it threw across its own feet.
        if (mode == CAST_MODE_MASK) {
            value = height;
            clip = maskClip(world);
        } else {
            value = 1.0;
            clip = cameraClip(world);
        }
    }

    let uvWeight = corner + vec2<f32>(0.5, 0.5);
    var output: CastOutput;
    // Nothing here tests depth, so the value only has to be inside the range the
    // clip volume accepts.
    output.position = vec4<f32>(clip, 0.5, 1.0);
    output.color = instance.color;
    output.uv = mix(instance.uvRect.xy, instance.uvRect.zw, uvWeight);
    output.local = corner;
    output.material = instance.material;
    output.param = instance.scale.z;
    output.value = value;
    return output;
}

@fragment
fn castFragmentMain(input: CastOutput) -> @location(0) vec4<f32> {
    var frag: MaterialInput;
    frag.local = input.local;
    frag.uv = input.uv;
    frag.color = input.color;
    frag.param = input.param;
    // A silhouette is a yes or no, so this pass wants the same membership the
    // G-buffer decided rather than a soft edge that would spread the shadow.
    frag.blended = false;

    let shaded = materialDispatch(input.material, frag);
    if (shaded.coverage <= 0.0) {
        discard;
    }

    // Green marks a pixel an occluder really covers, which is what lets the
    // raymarch tell an occluder from the halo the blur spreads around one:
    // blurring red alone would make a soft edge read as a short occluder and
    // every silhouette would grow a skirt of shadow it does not cast. The two
    // targets this writes take one channel each, and the blend is what resolves
    // overlap: max for the mask, so the tallest occluder wins, and min for the
    // drop shadows, so the darkest does.
    return vec4<f32>(input.value, 1.0, 0.0, 1.0);
}
