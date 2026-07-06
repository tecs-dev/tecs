#pragma language glsl4

struct LineData {
    vec4 points;              // x1, y1, x2, y2
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, packed flags (uint bits)
    vec4 centerRot;           // centerX, centerY, rotation, pad
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl.

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer LineOutput {
    LineData lines[];
};

varying vec4 vColor;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying vec2 vP1;             // Line start in world coords
varying vec2 vP2;             // Line end in world coords
varying float vLineWidth;
varying float vFlags;

#ifdef VERTEX

// Rotate point around center
vec2 rotatePoint(vec2 p, vec2 center, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    vec2 d = p - center;
    return center + vec2(d.x * c - d.y * s, d.x * s + d.y * c);
}

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_CENTERED[love_VertexID];

    int instanceID = love_InstanceID;
    LineData l = lines[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = l.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout).
    uint flagBits = floatBitsToUint(l.depthLayerLineFlags.w);
    if (blendPassFiltered(flagBits) || materialPassFiltered(flagBits)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 p1 = l.points.xy;
    vec2 p2 = l.points.zw;
    vec2 center = l.centerRot.xy;
    float rotation = l.centerRot.z;
    bool isScreenSpace = (flagBits & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (flagBits & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (flagBits & FLAG_VIRTUAL_COORDS) != 0u;

    float lineWidth = l.depthLayerLineFlags.z;
    if (lineWidth <= 0.0) lineWidth = 1.0;

    // Apply rotation to endpoints around center
    if (rotation != 0.0) {
        p1 = rotatePoint(p1, center, rotation);
        p2 = rotatePoint(p2, center, rotation);
    }

    // Calculate line direction and perpendicular
    vec2 dir = p2 - p1;
    float len = length(dir);
    if (len < 0.0001) {
        // Degenerate line (zero length)
        dir = vec2(1.0, 0.0);
        len = 1.0;
    }
    dir = dir / len;
    vec2 perp = vec2(-dir.y, dir.x);

    // Half width for the quad
    float halfWidth = lineWidth * 0.5;

    // Unit quad: x in [-1,1] along line, y in [-1,1] perpendicular
    // quadPos.x = -1 or 1 (along line)
    // quadPos.y = -1 or 1 (perpendicular)
    float t = quadPos.x * 0.5 + 0.5;  // Map from [-1,1] to [0,1]
    float s = quadPos.y;               // -1 or 1

    // World position along the line with perpendicular offset
    vec2 worldPos = mix(p1, p2, t) + perp * halfWidth * s;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = l.depthLayerLineFlags.x * result.w;

    vColor = l.color;
    vWorldPos = worldPos;
    vClipBounds = l.clipBounds;
    vP1 = p1;
    vP2 = p2;
    vLineWidth = lineWidth;
    // Fragment only needs the low flag bits (FLAG_UNLIT); the full packed
    // value exceeds float's 24-bit exact integer range once materialId is set.
    vFlags = float(flagBits & 0xFFFFu);
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    uint flags = uint(vFlags);
    bool antiAliased = RoughGeometry < 0.5;

    // Calculate distance from pixel to line segment
    vec2 pa = vWorldPos - vP1;
    vec2 ba = vP2 - vP1;
    float len2 = dot(ba, ba);
    float t = clamp(dot(pa, ba) / len2, 0.0, 1.0);
    vec2 closest = vP1 + t * ba;
    float dist = length(vWorldPos - closest);

    float halfWidth = vLineWidth * 0.5;

    if (antiAliased) {
        // Opaque with a 50%-coverage discard: the edge lands on the SDF
        // half-coverage contour (sub-pixel accurate, crisp) and every
        // drawn pixel writes full alpha, so the deferred composite has
        // no partial-alpha edge to darken into a rim.
        float edgeWidth = length(fwidth(vWorldPos)) * 1.2;
        float cov = 1.0 - smoothstep(halfWidth, halfWidth + edgeWidth, dist);
        if (cov < 0.5) discard;
    } else {
        // Hard cutoff
        if (dist > halfWidth) discard;
    }

    // Flat normal for lines (facing camera)
    vec3 normal = vec3(0.0, 0.0, 1.0);

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
