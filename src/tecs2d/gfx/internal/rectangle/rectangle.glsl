#pragma language glsl4

struct RectData {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a
    vec4 layerZRotLine; // layer, z, rotation, lineWidth
    vec4 cornerScale;   // rx, ry, scaleX, scaleY
    vec4 clipBounds;    // minX, minY, maxX, maxY (world coords, large values = no clip)
    uvec4 flags;        // packed flags, depth (as uint bits), pivotX (as uint bits), pivotY (as uint bits)
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl.

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer RectOutput {
    RectData rects[];
};

varying vec4 vColor;
varying vec2 vLocalPos;       // Local position in rect (-0.5 to 0.5)
varying vec2 vHalfSize;       // Half size of rectangle
varying vec2 vCornerRadius;   // Corner radius (rx, ry)
varying float vLineWidth;     // Line width (0 = filled)
varying float vFlags;         // Flags (as float, convert to uint in fragment)
varying vec2 vWorldPos;       // World position for clipping
varying vec4 vClipBounds;     // Clip bounds

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_UNIT[love_VertexID];

    int instanceID = love_InstanceID;
    RectData r = rects[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = r.layerZRotLine.x;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout).
    uint flagBits = r.flags.x;
    if (blendPassFiltered(flagBits) || materialPassFiltered(flagBits)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 pos = r.posSize.xy;
    vec2 size = r.posSize.zw;
    float rotation = r.layerZRotLine.z;
    float scaleX = r.cornerScale.z;
    float scaleY = r.cornerScale.w;

    // Read pivot from flags (stored as float bits)
    vec2 pivot = vec2(
        uintBitsToFloat(r.flags.z),
        uintBitsToFloat(r.flags.w)
    );

    // Check screen-space flags (encoded in upper bits by cull shader)
    bool isScreenSpace = (flagBits & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (flagBits & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (flagBits & FLAG_VIRTUAL_COORDS) != 0u;

    // Transform unit quad with scale and rotation around pivot point
    vec2 local = quadPos - pivot;  // Offset from pivot (0,0 to 1,1 quad → pivot-relative)
    // Apply scale
    vec2 scaled = local * size * vec2(scaleX, scaleY);
    // Apply rotation
    float c = cos(rotation);
    float sn = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * sn, scaled.x * sn + scaled.y * c);
    // Translate to world position (pivot point is at transform position)
    vec2 worldPos = pos + rotated;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    // Read pre-computed depth from cull shader (stored in flags.y)
    float depth = uintBitsToFloat(r.flags.y);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = depth * result.w;

    // Pass to fragment shader
    vColor = r.color;
    vec2 scaledSize = size * vec2(scaleX, scaleY);
    // SDF uses center-relative coords (0.5, 0.5), independent of pivot
    vec2 sdfLocal = quadPos - 0.5;
    vLocalPos = sdfLocal * scaledSize;  // Local pos in pixels (scaled), centered at (0,0)
    vHalfSize = scaledSize * 0.5;
    vCornerRadius = r.cornerScale.xy;
    vLineWidth = r.layerZRotLine.w;
    // Fragment only needs the low flag bits (FLAG_UNLIT); the full packed
    // value exceeds float's 24-bit exact integer range once materialId is set.
    vFlags = float(r.flags.x & 0xFFFFu);
    vWorldPos = worldPos;
    vClipBounds = r.clipBounds;

    return result;
}
#endif

#ifdef PIXEL
// Signed distance to rounded rectangle
// p: point relative to rect center
// b: half-size of rectangle
// r: corner radius (clamped to half-size)
float roundedBoxSDF(vec2 p, vec2 b, vec2 r) {
    r = min(r, b);  // Clamp radius to half-size
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - max(r.x, r.y);
}

void effect() {
    uint flags = uint(vFlags);
    bool antiAliased = RoughGeometry < 0.5;

    // SDF for rounded rectangle
    float dist = roundedBoxSDF(vLocalPos, vHalfSize, vCornerRadius);

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Factor 1.2 widens the transition to reduce sub-pixel crawl artifacts.
    float edgeWidth = min(length(fwidth(vLocalPos)) * 1.2, 2.0);

    // Opaque with a 50%-coverage discard: the edge lands on the SDF
    // half-coverage contour (sub-pixel accurate, crisp) and every drawn
    // pixel writes full alpha, so the deferred composite has no
    // partial-alpha edge to darken into a rim.
    if (vLineWidth <= 0.0) {
        // Filled mode: inside the shape
        if (antiAliased) {
            float cov = 1.0 - smoothstep(0.0, edgeWidth, dist);
            if (cov < 0.5) discard;
        } else {
            // Hard cutoff (rough mode)
            if (dist > 0.0) discard;
        }
    } else {
        // Outline mode: on the edge
        float innerDist = dist + vLineWidth;
        if (antiAliased) {
            float outerCov = 1.0 - smoothstep(0.0, edgeWidth, dist);
            float innerCov = smoothstep(-edgeWidth, 0.0, innerDist);
            if (outerCov * innerCov < 0.5) discard;
        } else {
            // Hard cutoff (rough mode)
            if (dist > 0.0 || innerDist < 0.0) discard;
        }
    }

    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    // Check unlit flag
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;

    // -- MATERIAL_BEGIN --
    love_Canvases[0] = vColor;
    love_Canvases[1] = vec4(0.5, 0.5, 1.0, litMarker);  // Flat normal
    love_Canvases[2] = DEFAULT_ORM;
    love_Canvases[3] = vec4(0.0);  // No emission for shapes
    // -- MATERIAL_END --
}
#endif
