// Resolves the G-buffer against the lights that reach each pixel.
//
// Inputs in declaration order: albedo, normal, orm, emission, occluders,
// dropShadowAO. The last two are read only when `scene.ambient.a` says the
// shadow lane ran, so one pipeline serves a frame with shadows and a frame
// without.
//
// Every read is `textureSampleLevel` rather than `textureSample`. An unlit
// fragment returns early and the march below samples inside a loop, so most of
// this runs in non-uniform control flow, where an implicit derivative is not
// defined; there is no mip chain on a graph target to pick a level from anyway.
//
// Works in world units. A light is a thing in the world, so the camera has to
// carry it the way it carries geometry, and the alternative of placing lights
// in target pixels on the host un-places them again the moment anything wants a
// world-space ray: the occluder mask is built with a world projection and the
// shadow march below is a world-space march. So the view arrives here and the
// fragment is taken back out to the world instead.
//
// Emission is added rather than lit. A surface that gives off light is not a
// surface a light reaches, so the term lands on top of the accumulated result:
// past the ambient, past every light, past the drop shadow, and on both sides of
// the unlit branch. That is what makes it a different thing from a material
// asking not to be lit, which replaces the lighting with the albedo instead of
// adding to it, and it is why a lamp can be lit and glowing at once.

struct Light {
    // xy in world units, z height, w radius.
    position: vec4<f32>,
    // rgb color, a intensity.
    color: vec4<f32>,
}

@group(2) @binding(0) var<storage, read> lights: array<Light>;
@group(2) @binding(1) var<storage, read> tileCounts: array<u32>;
@group(2) @binding(2) var<storage, read> tileLights: array<u32>;

// Tiles the view is divided into on each axis, and the lights one tile holds.
// `tecs.gfx.lighting.TILES` and `TILE_SLOTS` are the same two numbers, and the
// pair only works while they agree.
const LIGHT_TILES: i32 = 32;
const LIGHT_TILE_SLOTS: i32 = 64;

// Above this the mask's green channel says an occluder really covers the pixel.
// Below it the pixel is either empty or in the halo the blur spread, and a halo
// that counted would give every silhouette a skirt of shadow it does not cast.
const OCC_MARKER: f32 = 0.5;

// How sharply a shadow's far end fades. The ray's height crosses the occluder's
// over this much of a height, so an occluder does not simply stop blocking one
// sample later.
const OCC_SOFT: f32 = 0.06;

// Below this a light contributes nothing a viewer could see, so the march is
// skipped rather than run at its floor of four steps. This is what makes the
// cost proportional to what a light lights rather than to what its tile covers.
const MARCH_FLOOR: f32 = 0.05;

// Which tile a world position falls in.
//
// Clamped rather than tested, because a fragment at the very edge of the view
// can land a rounding error outside the rectangle its own camera produced, and
// the nearest tile is the right answer there.
fn lightTileOf(world: vec2<f32>, bounds: vec4<f32>) -> i32 {
    let span = max(bounds.zw - bounds.xy, vec2<f32>(1e-6));
    let across = (world - bounds.xy) / span;
    let cell = clamp(
        vec2<i32>(floor(across * f32(LIGHT_TILES))),
        vec2<i32>(0),
        vec2<i32>(LIGHT_TILES - 1),
    );
    return cell.y * LIGHT_TILES + cell.x;
}

// The fragment's world position: the inverse of what the camera's matrix did to
// the geometry that landed here.
fn worldOf(fragment: vec2<f32>) -> vec2<f32> {
    let offset = fragment - scene.viewport * 0.5;
    let c = cos(scene.rotation) / scene.zoom;
    let s = sin(scene.rotation) / scene.zoom;
    return scene.camera + vec2<f32>(offset.x * c - offset.y * s, offset.x * s + offset.y * c);
}

fn maskUV(world: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(dot(scene.maskXform.xy, world), dot(scene.maskXform.zw, world))
        + scene.maskParams.xy;
}

// Interleaved gradient noise, Jimenez 2014. A dither on where each sample lands
// along the ray, which turns the banding a fixed step count produces into grain
// the eye reads as softness. Cheaper than a blue-noise texture and needs no
// binding.
fn dither(pixel: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(pixel, vec2<f32>(0.06711056, 0.00583715))));
}

// How much of one light this fragment is cut off from, zero to one.
//
// One mask and one march per light, rather than a shadow pass per light. What
// the march is testing is whether the straight line from the fragment to the
// light passes under an occluder: the line rises from the ground at the fragment
// to the light's height at the light, so at a fraction t of the way there it
// stands at t of that height, and anything taller than that blocks it.
//
// The step count follows the light's own attenuation. A pixel at the fringe of a
// light's reach marches four steps and one in the middle marches all of them,
// which bounds the worst case at what the pixels that can actually see a
// difference cost.
fn marchShadow(
    world: vec2<f32>,
    lightAt: vec2<f32>,
    lightHeight: f32,
    attenuation: f32,
    noise: f32,
) -> f32 {
    let origin = maskUV(world);
    let reach = maskUV(lightAt);

    // Self-shadow is prevented by leaving the origin's own body rather than by a
    // bias. A fragment inside an occluder takes no hit until the ray has passed
    // through empty space, so a wall does not shadow itself and still shadows
    // the wall beside it.
    var left = textureSampleLevel(input4, passSampler, origin, 0.0).g <= OCC_MARKER;

    let ceiling = i32(scene.maskParams.z);
    let steps = clamp(i32(scene.maskParams.z * attenuation + 0.5), 4, ceiling);
    let stride = (reach - origin) / f32(steps);
    // Normalized against the height a full-height occluder stands, which is the
    // one number that puts a light's world height and a mask's zero-to-one
    // height in the same space.
    let rise = max(lightHeight / max(scene.maskParams.w, 1e-3), 1e-3);

    var shadow = 0.0;
    for (var step = 1; step <= steps; step = step + 1) {
        let t = (f32(step) - noise) / f32(steps);
        let sampled = textureSampleLevel(input4, passSampler, origin + stride * (f32(step) - noise), 0.0);
        let solid = sampled.g > OCC_MARKER;
        if (!left) {
            left = !solid;
            continue;
        }
        if (!solid) {
            continue;
        }
        shadow = max(shadow, smoothstep(0.0, OCC_SOFT, sampled.r - t * rise));
        if (shadow >= 1.0) {
            break;
        }
    }
    return shadow;
}

@fragment
fn lightingMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    let albedo = textureSampleLevel(input0, passSampler, input.uv, 0.0);
    let encoded = textureSampleLevel(input1, passSampler, input.uv, 0.0);
    let emitted = textureSampleLevel(input3, passSampler, input.uv, 0.0);
    let emission = emitted.rgb * emitted.a;

    // A material that asked not to be lit passes through at its own color, plus
    // whatever it emits: the flag says the lighting does not reach the surface,
    // and emission is the surface's own and is not lighting reaching it. The
    // G-buffer clears both attachments to zero, so anything nothing drew over
    // also takes this path and stays the clear color.
    if (encoded.a < 0.5) {
        return vec4<f32>(albedo.rgb + emission, albedo.a);
    }

    // Normals are stored biased into unsigned range, as the G-buffer format has
    // no signed representation.
    let normal = normalize(encoded.xyz * 2.0 - 1.0);
    let orm = textureSampleLevel(input2, passSampler, input.uv, 0.0);

    // Target pixels from the top left, which is the space the view inverts from
    // and the one a readback names a pixel in.
    let fragment = input.uv * scene.viewport;
    let world = worldOf(fragment);
    let surface = vec3<f32>(world, 0.0);
    let shadowed = scene.ambient.a > 0.5;
    let noise = dither(fragment);

    // Authored occlusion reaches indirect light only. A point light is a
    // directionally known contribution and is not hidden by a baked ambient
    // term; its own shadowing is handled separately below.
    var accumulated = albedo.rgb * scene.ambient.rgb * orm.r;

    // The lights binned to this fragment's tile rather than every light in the
    // scene. Without this the loop runs its whole body for every light however
    // far away it is, since falloff clamps to zero rather than rejecting, and a
    // scene's light count would be a per-pixel cost.
    let tile = lightTileOf(world, scene.bounds);
    let count = i32(tileCounts[tile]);
    let base = tile * LIGHT_TILE_SLOTS;
    for (var slot = 0; slot < count; slot = slot + 1) {
        let light = lights[tileLights[base + slot]];
        let toLight = light.position.xyz - surface;
        let distance = length(toLight);
        let radius = max(light.position.w, 1.0);

        // Smooth falloff to zero at the radius, so a light has bounded reach and
        // the lighting cost stays proportional to what it touches.
        var attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
        attenuation = attenuation * attenuation;

        let lambert = max(dot(normal, normalize(toLight)), 0.0);
        if (shadowed && attenuation * lambert > MARCH_FLOOR) {
            attenuation = attenuation
                * (1.0 - marchShadow(world, light.position.xy, light.position.z, attenuation, noise));
        }
        accumulated = accumulated + albedo.rgb * light.color.rgb * light.color.a * attenuation * lambert;
    }

    // After the loop and over the ambient too, which is the whole of what makes
    // this a different thing from the mask above rather than a weaker one. The
    // mask reaches a light's own contribution and has no path to the ambient
    // term at all, so in a scene lit mostly by ambient it is not merely fainter
    // than this: it is nothing.
    if (shadowed) {
        accumulated = accumulated * textureSampleLevel(input5, passSampler, input.uv, 0.0).r;
    }

    // Added after the multiply, so no light and no shadow scales it. A glowing
    // sign is as bright in the dark as under a lamp, which is the whole of what
    // makes it a sign, and the drop shadow above darkens the ground the sign
    // stands on without dimming the sign.
    return vec4<f32>(accumulated + emission, albedo.a);
}
