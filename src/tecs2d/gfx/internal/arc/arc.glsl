#pragma language glsl4

struct ArcData {
    vec4 posRadii;            // x, y, radiusX, radiusY
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, spare
    vec4 angles;              // startAngle, endAngle, rotation, pad
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
    vec4 pivot;               // pivotX, pivotY, pad, packed flags (uint bits)
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl. Arc blend modes route through per-blend batch
// buffers, so only the material pass filters here.

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer ArcOutput {
    ArcData arcs[];
};

varying vec4 vColor;
varying vec2 vLocalPos;
varying vec2 vRadii;          // radiusX, radiusY
varying float vLineWidth;
varying float vFlags;
varying vec2 vAngles;         // startAngle, endAngle
varying float vRotation;      // transform rotation
varying vec2 vWorldPos;
varying vec4 vClipBounds;

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_CENTERED[love_VertexID];

    int instanceID = love_InstanceID;
    ArcData a = arcs[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = a.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Material pass filtering (canonical packed layout).
    uint packed = floatBitsToUint(a.pivot.w);
    if (materialPassFiltered(packed)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 center = a.posRadii.xy;
    vec2 radii = a.posRadii.zw;  // radiusX, radiusY
    bool isScreenSpace = (packed & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (packed & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (packed & FLAG_VIRTUAL_COORDS) != 0u;

    // Unit quad spans -1 to 1, scale by radii
    vec2 localPos = quadPos;
    vec2 worldPos = center + localPos * radii;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = a.depthLayerLineFlags.x * result.w;

    vColor = a.color;
    vLocalPos = localPos;
    vRadii = radii;
    vLineWidth = a.depthLayerLineFlags.z;
    // Fragment only needs the low flag bits; they fit a float exactly.
    vFlags = float(packed & 0xFFFFu);
    vAngles = a.angles.xy;
    vRotation = a.angles.z;
    vWorldPos = worldPos;
    vClipBounds = a.clipBounds;
    return result;
}
#endif

#ifdef PIXEL
// Normalize angle to [0, 2*PI)
float normalizeAngle(float a) {
    const float TWO_PI = 6.28318530718;
    a = mod(a, TWO_PI);
    if (a < 0.0) a += TWO_PI;
    return a;
}

// Check if angle is within arc range (handles wrap-around)
bool isInArcRange(float angle, float start, float end) {
    angle = normalizeAngle(angle);
    start = normalizeAngle(start);
    end = normalizeAngle(end);

    if (start <= end) {
        // Simple case: arc doesn't wrap around
        return angle >= start && angle <= end;
    } else {
        // Arc wraps around 0/2*PI
        return angle >= start || angle <= end;
    }
}

void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    uint flags = uint(vFlags);
    bool antiAliased = RoughGeometry < 0.5;

    // SDF ellipse - distance is normalized so 1.0 = on the edge
    float dist = length(vLocalPos);  // vLocalPos is already in normalized space (-1 to 1)

    // Calculate angle of this pixel from center, accounting for rotation
    // Subtract rotation to "unrotate" the pixel position before checking arc range
    float pixelAngle = atan(vLocalPos.y, vLocalPos.x) - vRotation;

    // Check if pixel is within arc angular range
    if (!isInArcRange(pixelAngle, vAngles.x, vAngles.y)) {
        discard;
    }

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Kept tight (~1px, no widening) for a crisp edge, matching circle
    // and ellipse.
    float edgeWidth = min(length(fwidth(vLocalPos)), 0.05);

    // Handle outline vs filled mode
    if (vLineWidth > 0.0) {
        // Outline mode: lineWidth is in pixels, convert to normalized space
        // Average the radii for consistent line width
        float avgRadius = (vRadii.x + vRadii.y) * 0.5;
        float lineWidthNorm = vLineWidth / avgRadius;
        float innerEdge = max(1.0 - lineWidthNorm, 0.0);

        // Opaque with a 50%-coverage discard (see filled note below): no
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
        // Filled mode (pie slice). Opaque with a 50%-coverage discard: the
        // edge lands on the SDF half-coverage contour (sub-pixel accurate,
        // crisp) and every drawn pixel writes full alpha, so the deferred
        // composite has no partial-alpha edge to darken into a rim.
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
