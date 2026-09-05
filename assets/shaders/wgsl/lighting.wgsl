// Resolves the G-buffer into the `lit` target.
//
// Inputs in declaration order: albedo, normal, orm, emission.

@fragment
fn lightingMain(input: FullscreenOutput) -> @location(0) vec4<f32> {
    let albedo = textureSample(input0, passSampler, input.uv);
    let emission = textureSample(input3, passSampler, input.uv);
    // No light source reaches this build, so the resolve is the albedo the
    // geometry pass wrote plus what the surface emits. The pass, its four
    // inputs and its wider output format are what a lighting model needs, and
    // this is the body that model replaces: the normal and ORM attachments are
    // already written and already bound here.
    let emitted = emission.rgb * emission.a;
    return vec4<f32>(albedo.rgb + emitted, albedo.a);
}
