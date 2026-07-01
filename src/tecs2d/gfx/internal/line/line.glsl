#pragma language glsl4

struct LineData {
    vec4 points;              // x1, y1, x2, y2
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, flags (as float)
    vec4 centerRot;           // centerX, centerY, rotation, pad
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
};

// Flag constants (must match types.tl)
const uint FLAG_UNLIT = 0x1u;   // Skip lighting

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer LineOutput {
    LineData lines[];
};

uniform int BlendModePass;    // Current blend mode pass (-1 = render all, 0+ = render only matching blend ID)
uniform int MaterialPass;     // -1 = default pass (materialId=0 only), 0+ = specific material

varying vec4 vColor;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying vec2 vP1;             // Line start in world coords
varying vec2 vP2;             // Line end in world coords
varying float vLineWidth;
varying float vFlags;
varying float vIsScreenSpace; // For fragment shader clip bounds handling

#ifdef VERTEX
// Quad vertex positions for line shapes (2 triangles, CCW winding, -1 to 1 range)
const vec2 QUAD_POSITIONS[6] = vec2[6](
    vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),  // First triangle
    vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0)   // Second triangle
);

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
    vec2 quadPos = QUAD_POSITIONS[love_VertexID];

    int instanceID = love_InstanceID;
    LineData l = lines[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = l.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend mode pass filtering: skip lines that don't match current blend pass
    // flags contain blendId in bits 20-23, materialId in bits 24-31
    if (BlendModePass >= 0) {
        uint flagBits = uint(l.depthLayerLineFlags.w);
        int lineBlendId = int((flagBits >> 20u) & 0xFu);
        if (lineBlendId != BlendModePass) {
            return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    // Material pass filtering
    {
        uint flagBits = uint(l.depthLayerLineFlags.w);
        uint matId = (flagBits >> 24u) & 0xFFu;
        if (MaterialPass < 0) {
            if (matId != 0u) return vec4(2.0, 2.0, 2.0, 1.0);
        } else {
            if (int(matId) != MaterialPass) return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    vec2 p1 = l.points.xy;
    vec2 p2 = l.points.zw;
    vec2 center = l.centerRot.xy;
    float rotation = l.centerRot.z;
    // Screen-space flags encoded in centerRot.w by cull shader: 1.0 = screenSpace, 2.0 = ignoreZoom, 4.0 = virtualCoords
    float screenSpaceFlag = l.centerRot.w;
    int flagInt = int(screenSpaceFlag);
    bool isScreenSpace = (flagInt & 1) != 0;
    bool ignoresZoom = (flagInt & 2) != 0;
    bool usesVirtualCoords = (flagInt & 4) != 0;

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
    vFlags = l.depthLayerLineFlags.w;
    vIsScreenSpace = isScreenSpace ? 1.0 : 0.0;
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
    float alpha = 1.0;

    if (antiAliased) {
        // Anti-aliased edge (stable derivatives from linear vWorldPos varying).
        // Place the transition entirely outside the line's geometric edge so
        // the interior stays alpha=1 -- centering it on the edge mixes the
        // line color with the background and produces a dark fringe.
        float edgeWidth = length(fwidth(vWorldPos)) * 1.2;
        alpha = 1.0 - smoothstep(halfWidth, halfWidth + edgeWidth, dist);
        if (alpha < 0.01) discard;
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
    love_Canvases[0] = vec4(vColor.rgb, vColor.a * alpha);
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, litMarker);
    love_Canvases[2] = vec4(1.0, 0.5, 0.0, 1.0);  // ORM default (AO=1, roughness=0.5, metallic=0)
    love_Canvases[3] = vec4(0.0);  // No emission for shapes
    love_Canvases[4] = vec4(floor(gl_FragCoord.z * 255.0) / 255.0, fract(gl_FragCoord.z * 255.0), 0.0, 1.0); // Depth (16-bit RG)
    // -- MATERIAL_END --
}
#endif
