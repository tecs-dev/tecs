#pragma language glsl4

struct ArcData {
    vec4 posRadii;            // x, y, radiusX, radiusY
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, flags (as float)
    vec4 angles;              // startAngle, endAngle, rotation, pad
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
    vec4 pivot;               // pivotX, pivotY, pad, screenSpaceFlags
};

// Flag constants (must match types.tl)
const uint FLAG_UNLIT = 0x1u;   // Skip lighting

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer ArcOutput {
    ArcData arcs[];
};

uniform int MaterialPass;     // -1 = default pass (materialId=0 only), 0+ = specific material

varying vec4 vColor;
varying vec2 vLocalPos;
varying vec2 vRadii;          // radiusX, radiusY
varying float vLineWidth;
varying float vFlags;
varying vec2 vAngles;         // startAngle, endAngle
varying float vRotation;      // transform rotation
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
    ArcData a = arcs[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = a.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Material pass filtering: materialId packed in bits 8-15 of pivot.w alongside screenSpaceFlags
    {
        int packedPivotW = int(a.pivot.w);
        int matId = (packedPivotW >> 8) & 0xFF;
        if (MaterialPass < 0) {
            if (matId != 0) return vec4(2.0, 2.0, 2.0, 1.0);
        } else {
            if (matId != MaterialPass) return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    vec2 center = a.posRadii.xy;
    vec2 radii = a.posRadii.zw;  // radiusX, radiusY
    // Screen-space flags encoded in pivot.w by cull shader: 1.0 = screenSpace, 2.0 = ignoreZoom, 4.0 = virtualCoords
    float screenSpaceFlag = a.pivot.w;
    int flagInt = int(screenSpaceFlag);
    bool isScreenSpace = (flagInt & 1) != 0;
    bool ignoresZoom = (flagInt & 2) != 0;
    bool usesVirtualCoords = (flagInt & 4) != 0;

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
    vFlags = a.depthLayerLineFlags.w;
    vAngles = a.angles.xy;
    vRotation = a.angles.z;
    vWorldPos = worldPos;
    vClipBounds = a.clipBounds;
    vIsScreenSpace = isScreenSpace ? 1.0 : 0.0;
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

    float alpha = 1.0;

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Factor 1.2 widens the transition to reduce sub-pixel crawl artifacts.
    float edgeWidth = min(length(fwidth(vLocalPos)) * 1.2, 0.25);

    // Handle outline vs filled mode
    if (vLineWidth > 0.0) {
        // Outline mode: lineWidth is in pixels, convert to normalized space
        // Average the radii for consistent line width
        float avgRadius = (vRadii.x + vRadii.y) * 0.5;
        float lineWidthNorm = vLineWidth / avgRadius;
        float innerEdge = max(1.0 - lineWidthNorm, 0.0);

        if (antiAliased) {
            float outerAlpha = 1.0 - smoothstep(1.0, 1.0 + edgeWidth, dist);
            float innerAlpha = smoothstep(innerEdge - edgeWidth, innerEdge, dist);
            alpha = outerAlpha * innerAlpha;
            if (alpha < 0.01) discard;
        } else {
            // Hard cutoff (rough mode)
            if (dist > 1.0 || dist < innerEdge) discard;
        }
    } else {
        // Filled mode (pie slice)
        if (antiAliased) {
            alpha = 1.0 - smoothstep(1.0, 1.0 + edgeWidth, dist);
            if (alpha < 0.01) discard;
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
    love_Canvases[4] = vec4(floor(gl_FragCoord.z * 255.0) / 255.0, fract(gl_FragCoord.z * 255.0), 0.0, 1.0); // Depth (16-bit RG)
    // -- MATERIAL_END --
}
#endif
