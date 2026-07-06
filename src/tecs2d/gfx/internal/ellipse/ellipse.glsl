#pragma language glsl4

struct EllipseData {
    vec4 posRadii;            // x, y, radiusX, radiusY
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, flags (as float)
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
    vec4 pivot;               // pivotX, pivotY, rotation, pad
};

// Flag constants (must match types.tl)
const uint FLAG_UNLIT = 0x1u;   // Skip lighting

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer EllipseOutput {
    EllipseData ellipses[];
};

uniform int MaterialPass;     // -1 = default pass (materialId=0 only), 0+ = specific material

varying vec4 vColor;
varying vec2 vLocalPos;
varying vec2 vRadii;          // radiusX, radiusY
varying float vLineWidth;
varying float vFlags;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying float vIsScreenSpace; // For fragment shader clip bounds handling

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
    EllipseData e = ellipses[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = e.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Material pass filtering: materialId packed in bits 8-15 of pivot.w alongside screenSpaceFlags
    {
        int packedPivotW = int(e.pivot.w);
        int matId = (packedPivotW >> 8) & 0xFF;
        if (MaterialPass < 0) {
            if (matId != 0) return vec4(2.0, 2.0, 2.0, 1.0);
        } else {
            if (matId != MaterialPass) return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    vec2 center = e.posRadii.xy;
    vec2 radii = e.posRadii.zw;  // radiusX, radiusY
    vec2 pivot = e.pivot.xy;     // pivotX, pivotY (0.0-1.0 range)
    float rotation = e.pivot.z;
    // Screen-space flags encoded in pivot.w by cull shader: 1.0 = screenSpace, 2.0 = ignoreZoom, 4.0 = virtualCoords
    float screenSpaceFlag = e.pivot.w;
    int flagInt = int(screenSpaceFlag);
    bool isScreenSpace = (flagInt & 1) != 0;
    bool ignoresZoom = (flagInt & 2) != 0;
    bool usesVirtualCoords = (flagInt & 4) != 0;

    // Unit quad spans -1 to 1, convert pivot from 0-1 to -1 to 1 range
    vec2 pivotOffset = (pivot - 0.5) * 2.0;  // (0,0)->(-1,-1), (0.5,0.5)->(0,0), (1,1)->(1,1)

    // Offset local position by pivot (rotation will happen around pivot point)
    vec2 localPos = quadPos - pivotOffset;
    vec2 scaled = localPos * radii;

    // Apply rotation around pivot point
    float c = cos(rotation);
    float s = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);

    // Translate back: pivot point is at transform position
    vec2 worldPos = center + rotated;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = e.depthLayerLineFlags.x * result.w;

    vColor = e.color;
    vLocalPos = quadPos;  // Use quad pos for SDF (centered -1 to 1)
    vRadii = radii;
    vLineWidth = e.depthLayerLineFlags.z;
    vFlags = e.depthLayerLineFlags.w;
    vWorldPos = worldPos;
    vClipBounds = e.clipBounds;
    vIsScreenSpace = isScreenSpace ? 1.0 : 0.0;
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    uint flags = uint(vFlags);
    bool antiAliased = RoughGeometry < 0.5;

    // SDF ellipse - distance is normalized so 1.0 = on the edge
    // For ellipse: length(p / radii) = 1 on the edge
    float dist = length(vLocalPos);  // vLocalPos is already in normalized space (-1 to 1)
    float alpha = 1.0;

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Kept tight (~1px, no widening) for a crisp edge; the older 1.2x widen
    // + 0.25 clamp produced a visibly fuzzy halo on small shapes.
    float edgeWidth = min(length(fwidth(vLocalPos)), 0.05);

    // Handle outline vs filled mode
    if (vLineWidth > 0.0) {
        // Outline mode: lineWidth is in pixels, convert to normalized space
        // Average the radii for consistent line width
        float avgRadius = (vRadii.x + vRadii.y) * 0.5;
        float lineWidthNorm = vLineWidth / avgRadius;
        float innerEdge = max(1.0 - lineWidthNorm, 0.0);

        // Opaque with a 50%-coverage discard (matches filled mode): no
        // partial-alpha stroke edge for the deferred composite to rim.
        if (antiAliased) {
            float outerAlpha = 1.0 - smoothstep(1.0, 1.0 + edgeWidth, dist);
            float innerAlpha = smoothstep(innerEdge - edgeWidth, innerEdge, dist);
            float cov = outerAlpha * innerAlpha;
            if (cov < 0.5) discard;
        } else {
            // Hard cutoff (rough mode)
            if (dist > 1.0 || dist < innerEdge) discard;
        }
    } else {
        // Filled mode. Opaque with a 50%-coverage discard: the edge lands
        // on the SDF half-coverage contour (sub-pixel accurate, crisp) and
        // every drawn pixel writes full alpha, so the deferred composite
        // has no partial-alpha edge to darken into a rim.
        if (antiAliased) {
            float cov = 1.0 - smoothstep(1.0, 1.0 + edgeWidth, dist);
            if (cov < 0.5) discard;
        } else {
            // Hard cutoff (rough mode)
            if (dist > 1.0) discard;
        }
    }

    // Hemisphere normal for lighting (approximate for ellipse)
    vec3 normal = vec3(0.0, 0.0, 1.0);
    float r2 = dot(vLocalPos, vLocalPos);
    if (r2 < 1.0) {
        float z = sqrt(1.0 - r2);
        normal = normalize(vec3(vLocalPos, z));
    }

    // Check unlit flag
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;

    // -- MATERIAL_BEGIN --
    love_Canvases[0] = vec4(vColor.rgb, vColor.a * alpha);
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, litMarker);
    love_Canvases[2] = vec4(1.0, 0.5, 0.0, 1.0);  // ORM default (AO=1, roughness=0.5, metallic=0)
    love_Canvases[3] = vec4(0.0);  // No emission for shapes
    // -- MATERIAL_END --
}
#endif
