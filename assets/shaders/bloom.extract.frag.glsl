#version 450
// Extracts a soft brightness threshold from the resolved opaque scene. Bloom
// runs before forward geometry, so transparent meshes and 2D UI stay crisp.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D sceneTexture;
layout(set = 3, binding = 0) uniform Bloom {
    // x threshold, y soft knee, z intensity.
    vec4 tuning;
} bloom;

void main() {
    vec3 color = texture(sceneTexture, vUV).rgb;
    float brightness = max(max(color.r, color.g), color.b);
    float knee = max(bloom.tuning.y, 1e-4);
    float soft = clamp(brightness - bloom.tuning.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contribution = max(brightness - bloom.tuning.x, soft) / max(brightness, 1e-4);
    outColor = vec4(color * contribution * bloom.tuning.z, 1.0);
}
