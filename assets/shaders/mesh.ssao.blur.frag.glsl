#version 450
// One axis of the half-resolution edge-aware AO blur. Depth and normals keep
// the filter from pulling a dark wall across its silhouette or onto a sprite.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D aoTexture;
layout(set = 2, binding = 1) uniform sampler2D depthTexture;
layout(set = 2, binding = 2) uniform sampler2D normalTexture;
layout(set = 3, binding = 0) uniform Blur { vec4 step; } blur;

const float WEIGHTS[5] = float[5](0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162);

void main() {
    vec4 centerEncoded = texture(normalTexture, vUV);
    if (centerEncoded.a <= 0.1 || centerEncoded.a >= 0.9) {
        outColor = vec4(1.0);
        return;
    }
    vec3 centerNormal = normalize(centerEncoded.xyz * 2.0 - 1.0);
    float centerDepth = texture(depthTexture, vUV).r;
    float sum = texture(aoTexture, vUV).r * WEIGHTS[0];
    float total = WEIGHTS[0];
    for (int tap = 1; tap < 5; tap++) {
        for (int side = -1; side <= 1; side += 2) {
            vec2 sampleUV = vUV + blur.step.xy * float(tap * side);
            vec4 encoded = texture(normalTexture, sampleUV);
            if (encoded.a <= 0.1 || encoded.a >= 0.9) { continue; }
            vec3 normal = normalize(encoded.xyz * 2.0 - 1.0);
            float depth = texture(depthTexture, sampleUV).r;
            float edge = exp(-abs(depth - centerDepth) * 500.0)
                       * pow(max(dot(normal, centerNormal), 0.0), 8.0);
            float weight = WEIGHTS[tap] * edge;
            sum += texture(aoTexture, sampleUV).r * weight;
            total += weight;
        }
    }
    float visibility = sum / max(total, 1e-5);
    outColor = vec4(visibility, visibility, visibility, 1.0);
}
