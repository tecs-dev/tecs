// Writes the resolved lighting into the eight-bit `scene` target that anything
// running between here and the present composites over.
//
// Inputs in declaration order: lit, bloomA. The bloom term is scaled by
// `scene.bloom.w`, which is zero when the frame ran no bloom chain, so one
// pipeline serves both and the bloom targets need not hold anything meaningful
// when the lane is off.

@fragment
fn compositeMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    let lit = textureSample(input0, passSampler, input.uv);
    let bloom = textureSample(input1, passSampler, input.uv).rgb * scene.bloom.w;
    return vec4<f32>(lit.rgb + bloom, lit.a);
}
