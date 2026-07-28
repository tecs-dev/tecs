#version 450
// Puts the scene target on the swapchain, one texel to one pixel.
//
// A copy, and separate from the composite shader on purpose: composite turns
// the lit buffer into the scene image and is where anything about how the
// scene looks belongs, while this runs after everything that writes the scene
// and only moves it. Sharing one source would make an edit to either land in
// both.
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D sceneTexture;
void main() { outColor = texture(sceneTexture, vUV); }
