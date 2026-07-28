#version 450
// One axis of a separable blur over the occluder mask.
//
// Run twice, across and then down, which is nine taps twice instead of
// eighty-one. What it buys is a soft edge on every shadow in the scene for two
// fullscreen passes rather than for anything per light: the raymarch samples
// the blurred mask, so the softness costs the march nothing at all.
//
// Only the height is blurred. The marker channel is taken from the center tap
// and passed through, because it is what tells the march an occluder from the
// halo this spreads around one, and a blurred marker would make every
// silhouette grow a skirt of shadow it does not cast.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outMask;

layout(set = 2, binding = 0) uniform sampler2D maskTexture;

layout(set = 3, binding = 0) uniform Blur {
    // xy one step along the axis being blurred, in UV. The other axis is zero,
    // which is what makes this one shader for both passes.
    vec4 step;
} blur;

// Nine taps at unit spacing, normalized. Wide enough that the softest edge is
// several pixels and narrow enough that a shadow still has a shape.
const float WEIGHTS[5] = float[5](0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162);

void main() {
    vec4 center = texture(maskTexture, vUV);
    float height = center.r * WEIGHTS[0];
    for (int tap = 1; tap < 5; tap++) {
        vec2 offset = blur.step.xy * float(tap);
        height += texture(maskTexture, vUV + offset).r * WEIGHTS[tap];
        height += texture(maskTexture, vUV - offset).r * WEIGHTS[tap];
    }
    outMask = vec4(height, center.g, 0.0, 1.0);
}
