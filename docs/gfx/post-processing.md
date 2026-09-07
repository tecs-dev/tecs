---
title: Post-processing
description: Extend the render graph with custom WGSL effects and animated parameters.
---

# Post-processing

A pass names its inputs and outputs and runs at its declared position in the
render graph. Custom fullscreen effects define `postprocess` in WGSL. For a
final color grade, replace the body of `present`:

```nupp
tecs.gpu.passes.setShader("present", [=[
fn postprocess(uv: vec2<f32>) -> vec4<f32> {
    let color = textureSample(input0, passSampler, uv);
    let gray = dot(color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    return vec4<f32>(mix(color.rgb, vec3<f32>(gray), params.values[0].x), color.a);
}
]=])
tecs.gpu.passes.setParameters("present", {0.5})
```

The renderer supplies `input0`, `input1`, and subsequent textures in the order
of the pass's inputs, plus `passSampler` and the scene uniform. A depth input is
`texture_depth_2d`; read it with `textureLoad`. Parameters occupy four `vec4`
values, so the first four numbers are `params.values[0]`. Omitted numbers are
zero. Setting the same values does nothing; changing parameters updates a
uniform without recompiling shaders or reallocating render targets.

Composited color uses premultiplied alpha. Preserve that convention when
returning translucent colors; the final pass blends over the window clear
color. Emission and bloom may carry RGB even where alpha is zero.

To chain effects, declare a target, then insert a pass before the next consumer.
Supply `shader` and optional `parameters` in the pass declaration. A pass can
read only targets produced earlier, cannot read its own output, and a custom
effect writes one color target. Empty outputs draw into the presentation image.
Targets with `scale = 0.5` have half the width and height. A depth-attached pass
must use full-size targets.

The built-in names remain insertion points: `geometry`, `lighting`,
`bloomExtract`, `bloomBlurX`, `bloomBlurY`, `composite`, `forward`, and `present`.
Custom bodies execute regardless of the bloom and shadow toggles. In a scene
with multiple views, the graph runs independently for each view.

Run `nupp task ex-postprocess` for a grayscale and vignette effect.

<img src="/images/gfx-postprocess.png" alt="A custom grayscale and vignette pass over the scene." />
