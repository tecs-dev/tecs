#pragma language glsl4

// Shadow mask shader for circle occluders.
// Reads from the shadow-only buffer populated by the cull shader's dual-write.

struct CircleData {
    vec4 posRadius;
    vec4 color;             // rgb = color, a = occluderHeight (from cull shader)
    vec4 depthLayerLineFlags;  // depth, layer, unused, flags
    vec4 clipBounds;
};

layout(std430) readonly buffer CircleOutput {
    CircleData circles[];
};

uniform mat4 ShadowViewProj;

varying vec2 vLocalPos;
varying float vOccluderHeight;

#ifdef VERTEX
// Quad vertex positions for SDF shapes (2 triangles, CCW winding, -1 to 1 range)
const vec2 QUAD_POSITIONS[6] = vec2[6](
    vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),  // First triangle
    vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0)   // Second triangle
);

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS[love_VertexID];

    int instanceID = love_InstanceID;
    CircleData c = circles[instanceID];

    vec2 center = c.posRadius.xy;
    float radius = c.posRadius.z;

    vec2 localPos = quadPos;
    vec2 worldPos = center + localPos * radius;
    vec2 screenPos = (ShadowViewProj * vec4(worldPos, 0.0, 1.0)).xy;

    vLocalPos = localPos;
    vOccluderHeight = c.color.a;  // occluderHeight was encoded in color.a by cull shader
    return transform_projection * vec4(screenPos, 0.0, 1.0);
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    float dist = length(vLocalPos);
    if (dist > 1.0) discard;

    float normalizedHeight = clamp(vOccluderHeight, 0.0, 1.0);

    // G=1 marks actual occluder pixels (distinguished from blur halo by lighting shader)
    return vec4(normalizedHeight, 1.0, 0.0, 1.0);
}
#endif
