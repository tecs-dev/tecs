#version 450
// Multiplies SSAO into ORM red while the pipeline's multiply blend preserves
// roughness, metallic, alpha, and every non-mesh pixel.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D aoTexture;
layout(set = 2, binding = 1) uniform sampler2D normalTexture;

void main() {
    float marker = texture(normalTexture, vUV).a;
    float visibility = marker > 0.1 && marker < 0.9 ? texture(aoTexture, vUV).r : 1.0;
    outColor = vec4(visibility, 1.0, 1.0, 1.0);
}
