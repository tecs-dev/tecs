// The three fullscreen filters: the occluder blur, the bloom threshold, and the
// bloom blur.
//
// One file and three entry points, because each is a fragment body over one
// declared input and the backend builds a module per pass from the entry it
// names. Each blur runs twice, across and then down, which is nine taps twice
// instead of eighty-one.
//
// Neither blur takes a uniform. The step along the axis is one texel of the
// input, which the shader reads from the texture it was handed, so a pass that
// blurs a half-scale target needs to be told nothing about the frame.

// Normalized nine-tap Gaussian kernel shared by both separable filters. Each
// entry point supplies its own edge policy and sampled channels.
const GAUSSIAN: array<f32, 5> = array<f32, 5>(
    0.2270270,
    0.1945946,
    0.1216216,
    0.0540541,
    0.0162162,
);

fn texelStep(horizontal: bool) -> vec2<f32> {
    let size = vec2<f32>(textureDimensions(input0, 0));
    if (horizontal) {
        return vec2<f32>(1.0 / max(size.x, 1.0), 0.0);
    }
    return vec2<f32>(0.0, 1.0 / max(size.y, 1.0));
}

// One axis of a separable blur over the occluder mask.
//
// What it buys is a soft edge on every shadow in the scene for two fullscreen
// passes rather than for anything per light: the raymarch samples the blurred
// mask, so the softness costs the march nothing at all.
//
// Only the height is blurred. The marker channel is taken from the center tap
// and passed through, because it is what tells the march an occluder from the
// halo this spreads around one, and a blurred marker would make every silhouette
// grow a skirt of shadow it does not cast.
fn occluderBlur(uv: vec2<f32>, horizontal: bool) -> vec4<f32> {
    let step = texelStep(horizontal);
    let center = textureSample(input0, passSampler, uv);
    var height = center.r * GAUSSIAN[0];
    for (var tap = 1; tap < 5; tap = tap + 1) {
        let offset = step * f32(tap);
        height = height + textureSample(input0, passSampler, uv + offset).r * GAUSSIAN[tap];
        height = height + textureSample(input0, passSampler, uv - offset).r * GAUSSIAN[tap];
    }
    return vec4<f32>(height, center.g, 0.0, 1.0);
}

@fragment
fn occluderBlurXMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return occluderBlur(input.uv, true);
}

@fragment
fn occluderBlurYMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return occluderBlur(input.uv, false);
}

// Extracts a soft brightness threshold from the resolved scene. Bloom runs on
// the lit target rather than on the composited one, so the forward pass's
// blended content and anything a game composites afterwards stay crisp.
@fragment
fn bloomExtractMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    let color = textureSample(input0, passSampler, input.uv).rgb;
    let brightness = max(max(color.r, color.g), color.b);
    let knee = max(scene.bloom.y, 1e-4);
    var soft = clamp(brightness - scene.bloom.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    let contribution = max(brightness - scene.bloom.x, soft) / max(brightness, 1e-4);
    return vec4<f32>(color * contribution * scene.bloom.z, 1.0);
}

fn bloomBlur(uv: vec2<f32>, horizontal: bool) -> vec4<f32> {
    let step = texelStep(horizontal);
    var color = textureSample(input0, passSampler, uv).rgb * GAUSSIAN[0];
    for (var tap = 1; tap < 5; tap = tap + 1) {
        let offset = step * f32(tap);
        color = color + textureSample(input0, passSampler, uv + offset).rgb * GAUSSIAN[tap];
        color = color + textureSample(input0, passSampler, uv - offset).rgb * GAUSSIAN[tap];
    }
    return vec4<f32>(color, 1.0);
}

@fragment
fn bloomBlurXMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return bloomBlur(input.uv, true);
}

@fragment
fn bloomBlurYMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return bloomBlur(input.uv, false);
}
