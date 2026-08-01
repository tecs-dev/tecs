#version 450
#pragma tecs variants BLOOM=1
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D litTexture;
#ifdef BLOOM
layout(set = 2, binding = 1) uniform sampler2D bloomTexture;
#endif
void main() {
    outColor = texture(litTexture, vUV);
#ifdef BLOOM
    outColor.rgb += texture(bloomTexture, vUV).rgb;
#endif
}
