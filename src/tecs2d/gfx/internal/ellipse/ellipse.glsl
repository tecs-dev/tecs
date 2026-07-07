#pragma language glsl4

struct EllipseData {
    vec4 posRadii;            // x, y, radiusX, radiusY
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, spare
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
    vec4 pivot;               // pivotX, pivotY, rotation, packed flags (uint bits)
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl. Non-alpha blend modes are not routed for
// ellipses yet, so only the material pass filters here.

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer EllipseOutput {
    EllipseData ellipses[];
};

varying vec4 vColor;
varying vec2 vLocalPos;
varying vec2 vRadii;          // radiusX, radiusY
varying float vLineWidth;
varying float vFlags;
varying vec2 vWorldPos;
varying vec4 vClipBounds;

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_CENTERED[love_VertexID];

    int instanceID = love_InstanceID;
    EllipseData e = ellipses[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = e.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Material pass filtering (canonical packed layout).
    uint packed = floatBitsToUint(e.pivot.w);
    if (materialPassFiltered(packed)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 center = e.posRadii.xy;
    vec2 radii = e.posRadii.zw;  // radiusX, radiusY
    vec2 pivot = e.pivot.xy;     // pivotX, pivotY (0.0-1.0 range)
    float rotation = e.pivot.z;
    bool isScreenSpace = (packed & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (packed & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (packed & FLAG_VIRTUAL_COORDS) != 0u;

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
    // Fragment only needs the low flag bits; they fit a float exactly.
    vFlags = float(packed & 0xFFFFu);
    vWorldPos = worldPos;
    vClipBounds = e.clipBounds;
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
    love_Canvases[0] = vColor;
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, litMarker);
    love_Canvases[2] = DEFAULT_ORM;
    love_Canvases[3] = vec4(0.0);  // No emission for shapes
    // -- MATERIAL_END --
}
#endif
