#pragma language glsl4

struct CircleData {
    vec4 posRadius;           // x, y, radius, packed flags (uint bits)
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, spare
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl.

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer CircleOutput {
    CircleData circles[];
};

varying vec4 vColor;
varying vec2 vLocalPos;
varying float vRadius;
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
    CircleData c = circles[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = c.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout).
    uint packed = floatBitsToUint(c.posRadius.w);
    if (blendPassFiltered(packed) || materialPassFiltered(packed)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 center = c.posRadius.xy;
    float radius = c.posRadius.z;
    bool isScreenSpace = (packed & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (packed & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (packed & FLAG_VIRTUAL_COORDS) != 0u;

    // Unit quad spans -1 to 1, scale by radius
    vec2 localPos = quadPos;
    vec2 worldPos = center + localPos * radius;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = c.depthLayerLineFlags.x * result.w;

    vColor = c.color;
    vLocalPos = localPos;
    vRadius = radius;
    vLineWidth = c.depthLayerLineFlags.z;
    // Fragment only needs the low flag bits; they fit a float exactly.
    vFlags = float(packed & 0xFFFFu);
    vWorldPos = worldPos;
    vClipBounds = c.clipBounds;
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    uint flags = uint(vFlags);
    bool antiAliased = RoughGeometry < 0.5;

    // SDF circle
    float dist = length(vLocalPos);

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Using fwidth(vLocalPos) instead of fwidth(dist) eliminates directional
    // variation. Kept tight (~1px, no widening) for a crisp edge; the older
    // 1.2x widen + 0.25 clamp produced a visibly fuzzy halo on small shapes.
    float edgeWidth = min(length(fwidth(vLocalPos)), 0.05);

    // Handle outline vs filled mode. Antialiased edges are placed
    // entirely outside the geometric boundary (smoothstep low = the
    // boundary, high = boundary + edgeWidth) so the interior stays
    // alpha=1. Centering the transition on the boundary mixes the
    // shape's color with the background through the inner half of
    // the transition, producing a dark fringe on dark backgrounds.
    if (vLineWidth > 0.0) {
        // Outline mode: lineWidth is in pixels, convert to normalized space
        float lineWidthNorm = vLineWidth / vRadius;
        float innerEdge = max(1.0 - lineWidthNorm, 0.0);  // Clamp to prevent negative

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

    // Hemisphere normal for lighting (flattened for softer shading)
    // Using 0.5 multiplier makes the hemisphere less steep
    vec3 normal = normalize(vec3(vLocalPos * 0.5, 1.0));

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
