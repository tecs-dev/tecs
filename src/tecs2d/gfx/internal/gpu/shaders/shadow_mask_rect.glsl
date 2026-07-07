#pragma language glsl4

// Shadow mask shader for rectangle occluders.
// Reads from the shadow-only buffer populated by the cull shader's dual-write.

struct RectData {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a (a = occluderHeight from cull shader)
    vec4 layerZRotLine; // layer, z, rotation, unused (for shadow output)
    vec4 cornerScale;   // rx, ry, scaleX, scaleY
    vec4 clipBounds;    // minX, minY, maxX, maxY
    uvec4 flags;        // flags, depth, pivotX, pivotY
};

layout(std430) readonly buffer RectOutput {
    RectData rects[];
};

varying vec2 vLocalPos;
varying vec2 vHalfSize;
varying vec2 vCornerRadius;
varying float vOccluderHeight;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 quadPos = MASK_QUAD_UNIT[love_VertexID];

    int instanceID = love_InstanceID;
    RectData r = rects[instanceID];

    vec2 pos = r.posSize.xy;
    vec2 size = r.posSize.zw;
    float rotation = r.layerZRotLine.z;
    float scaleX = r.cornerScale.z;
    float scaleY = r.cornerScale.w;

    vec2 pivot = vec2(
        uintBitsToFloat(r.flags.z),
        uintBitsToFloat(r.flags.w)
    );

    // Transform unit quad with scale and rotation around pivot point
    vec2 local = quadPos - pivot;
    vec2 scaled = local * size * vec2(scaleX, scaleY);
    float c = cos(rotation);
    float sn = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * sn, scaled.x * sn + scaled.y * c);
    vec2 worldPos = pos + rotated;

    vec2 screenPos = shadowMaskToScreen(worldPos);

    // SDF uses center-relative coords
    vec2 scaledSize = size * vec2(scaleX, scaleY);
    vec2 sdfLocal = quadPos - 0.5;
    vLocalPos = sdfLocal * scaledSize;
    vHalfSize = scaledSize * 0.5;
    vCornerRadius = r.cornerScale.xy;
    vOccluderHeight = r.color.a;  // occluderHeight was encoded in color.a by cull shader

    return transform_projection * vec4(screenPos, 0.0, 1.0);
}
#endif

#ifdef PIXEL
// Signed distance to rounded rectangle
float roundedBoxSDF(vec2 p, vec2 b, vec2 r) {
    r = min(r, b);
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - max(r.x, r.y);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    // SDF check - only inside the shape casts shadow (always filled for shadows)
    float dist = roundedBoxSDF(vLocalPos, vHalfSize, vCornerRadius);
    if (dist > 0.0) discard;
    return encodeOccluder(vOccluderHeight);
}
#endif
