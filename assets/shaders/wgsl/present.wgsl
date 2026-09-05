// Draws the finished scene onto the swapchain.
//
// The pass declares a clear, so the window's background is what the scene is
// blended over: a pixel nothing drew carries the albedo clear's zero alpha all
// the way here and leaves the background showing.

@fragment
fn presentMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return textureSample(input0, passSampler, input.uv);
}
