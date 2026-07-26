#version 450
// Emits a fullscreen triangle and the UV to sample a full-target texture.
//
// The V coordinate is flipped against the NDC Y: NDC +Y is up while texture
// V runs down from the top-left, so a pass that samples its input without
// this correction produces a vertically mirrored image, which reads as a
// content bug rather than a coordinate one.
layout(location = 0) out vec2 vUV;
void main() {
    vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    vUV = vec2(corner.x, 1.0 - corner.y);
}
