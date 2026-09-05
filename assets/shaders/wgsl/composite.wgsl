// Writes the resolved lighting into the eight-bit `scene` target that anything
// running between here and the present composites over.

@fragment
fn compositeMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    return textureSample(input0, passSampler, input.uv);
}
