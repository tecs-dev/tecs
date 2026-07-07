#pragma language glsl4

// Shadow mask shader for circle occluders.
// Reads from the shadow-only buffer populated by the cull shader's dual-write.

struct CircleData {
    vec4 posRadius;
    vec4 color;             // rgb = color, a = occluderHeight (from cull shader)
    vec4 depthLayerLineFlags;  // depth, layer, unused, unused (zeroed for shadow output)
    vec4 clipBounds;
};

layout(std430) readonly buffer CircleOutput {
    CircleData circles[];
};

varying vec2 vLocalPos;
varying float vOccluderHeight;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 quadPos = MASK_QUAD_CENTERED[love_VertexID];

    int instanceID = love_InstanceID;
    CircleData c = circles[instanceID];

    vec2 center = c.posRadius.xy;
    float radius = c.posRadius.z;

    vec2 localPos = quadPos;
    vec2 worldPos = center + localPos * radius;
    vec2 screenPos = shadowMaskToScreen(worldPos);

    vLocalPos = localPos;
    vOccluderHeight = c.color.a;  // occluderHeight was encoded in color.a by cull shader
    return transform_projection * vec4(screenPos, 0.0, 1.0);
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    float dist = length(vLocalPos);
    if (dist > 1.0) discard;
    return encodeOccluder(vOccluderHeight);
}
#endif
