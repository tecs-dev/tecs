#version 450
layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 2) in vec2 vLocal;
layout(location = 3) flat in int vMaterial;
layout(location = 4) flat in float vParam;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2DArray images;

const int MATERIAL_TEXTURED = 0;
const int MATERIAL_CIRCLE = 1;
const int MATERIAL_ROUNDED = 2;

// Signed distance to a rounded box, negative inside.
float roundedBox(vec2 p, vec2 extent, float radius) {
    vec2 q = abs(p) - extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    // Coverage decides membership, not opacity. The G-buffer pass writes with
    // replace rather than blend, so a partially covered edge fragment would
    // overwrite what is behind it instead of blending into it. Rejecting below
    // half coverage keeps the silhouette right; smooth edges need either
    // multisampling or the forward-blended path, both of which follow depth.
    if (vMaterial != MATERIAL_TEXTURED) {
        float distance;
        if (vMaterial == MATERIAL_CIRCLE) {
            distance = length(vLocal) - 0.5;
        } else {
            distance = roundedBox(vLocal, vec2(0.5), vParam);
        }
        if (distance > 0.0) { discard; }
    }

    // Untextured geometry samples layer zero, so both paths land here.
    albedo = texture(images, vUV) * vColor;
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
