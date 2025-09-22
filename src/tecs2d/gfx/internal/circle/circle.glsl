#pragma language glsl4

struct CircleData {
    vec4 posRadius;           // x, y, radius, screenSpaceFlags|blendId
    vec4 color;               // r, g, b, a
    vec4 depthLayerLineFlags; // depth, layer, lineWidth, flags (as float)
    vec4 clipBounds;          // minX, minY, maxX, maxY (world coords)
};

// Flag constants (must match types.tl)
const uint FLAG_UNLIT = 0x1u;   // Skip lighting

// 0.0 = smooth SDF edges, 1.0 = hard pixel cutoff. Set per-frame from
// pipeline.roughGeometry.
uniform float RoughGeometry;

layout(std430) readonly buffer CircleOutput {
    CircleData circles[];
};

uniform int BlendModePass;    // Current blend mode pass (-1 = render all, 0+ = render only matching blend ID)
uniform int MaterialPass;     // -1 = default pass (materialId=0 only), 0+ = specific material

varying vec4 vColor;
varying vec2 vLocalPos;
varying float vRadius;
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
    CircleData c = circles[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = c.depthLayerLineFlags.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend mode pass filtering: skip circles that don't match current blend pass
    // posRadius.w contains packed screenSpaceFlags (bits 0-2), blendId (bits 4-7), materialId (bits 8-15)
    if (BlendModePass >= 0) {
        int packedFlags = int(c.posRadius.w);
        int circleBlendId = (packedFlags >> 4) & 0xF;
        if (circleBlendId != BlendModePass) {
            return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    // Material pass filtering
    {
        int packedFlags = int(c.posRadius.w);
        int matId = (packedFlags >> 8) & 0xFF;
        if (MaterialPass < 0) {
            if (matId != 0) return vec4(2.0, 2.0, 2.0, 1.0);
        } else {
            if (matId != MaterialPass) return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    vec2 center = c.posRadius.xy;
    float radius = c.posRadius.z;
    // Screen-space flags encoded in posRadius.w by cull shader: bits 0-2 = screenSpace flags, bits 4-7 = blendId
    int packedScreenFlags = int(c.posRadius.w) & 0x7;  // Extract bits 0-2
    bool isScreenSpace = (packedScreenFlags & 1) != 0;
    bool ignoresZoom = (packedScreenFlags & 2) != 0;
    bool usesVirtualCoords = (packedScreenFlags & 4) != 0;

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
    vFlags = c.depthLayerLineFlags.w;
    vWorldPos = worldPos;
    vClipBounds = c.clipBounds;
    vIsScreenSpace = isScreenSpace ? 1.0 : 0.0;
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
    float alpha = 1.0;

    // Stable edge width from linear varying derivatives (constant per-triangle).
    // Using fwidth(vLocalPos) instead of fwidth(dist) eliminates directional variation.
    // Factor 1.2 widens the transition to ~3.4 pixels, reducing per-frame alpha change
    // from sub-pixel camera shifts (mimics the gradual transitions of texture filtering).
    float edgeWidth = min(length(fwidth(vLocalPos)) * 1.2, 0.25);

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
        // Filled mode
        if (antiAliased) {
            alpha = 1.0 - smoothstep(1.0, 1.0 + edgeWidth, dist);
            if (alpha < 0.01) discard;
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
    love_Canvases[0] = vec4(vColor.rgb, vColor.a * alpha);
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, litMarker);
    love_Canvases[2] = vec4(1.0, 0.5, 0.0, 1.0);  // ORM default (AO=1, roughness=0.5, metallic=0)
    love_Canvases[3] = vec4(0.0);  // No emission for shapes
    love_Canvases[4] = vec4(floor(gl_FragCoord.z * 255.0) / 255.0, fract(gl_FragCoord.z * 255.0), 0.0, 1.0); // Depth (16-bit RG)
    // -- MATERIAL_END --
}
#endif
