#version 450
// One axis of the optional separable bloom blur.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D sourceTexture;
layout(set = 3, binding = 0) uniform Blur { vec4 step; } blur;

#include "gaussian.glsl"

void main() {
    vec3 color = texture(sourceTexture, vUV).rgb * GAUSSIAN_WEIGHTS[0];
    for (int tap = 1; tap < 5; tap++) {
        vec2 offset = blur.step.xy * float(tap);
        color += texture(sourceTexture, vUV + offset).rgb * GAUSSIAN_WEIGHTS[tap];
        color += texture(sourceTexture, vUV - offset).rgb * GAUSSIAN_WEIGHTS[tap];
    }
    outColor = vec4(color, 1.0);
}
