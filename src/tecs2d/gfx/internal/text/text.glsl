#pragma language glsl4
// Two-tier text rendering shader
// Reads from TextHeader and GlyphData buffers via VisibleGlyph indices.
// Reduces per-glyph data from 96 bytes to 8 bytes (indices only).
// Supports both bitmap fonts (nearest sampling) and MSDF fonts (linear sampling with effects).

// Camera uniforms (CameraPos, CameraZoom, ScreenHalf, CameraSubPixel, VirtualSize,
// ScreenSize, RenderSize) and depth uniforms (MaxLayer, MaxZ, MaxY, masks, SortModes)
// are provided by RenderParams SSBO via render_common.glsl.
// Layer checks, sort modes, getSortMode, and computeDepth are provided by depth_common.glsl.

// Text header data (per-entity)
struct TextHeader {
    vec4 posLayer;       // x, y, z, layer
    vec4 rotScaleFlags;  // rotation, scaleX, scaleY, flags
    vec4 color;          // r, g, b, a
    vec4 clipBounds;     // minX, minY, maxX, maxY
    vec4 fontMeta;       // fontLayer, glyphStartIdx, glyphCount, textWidth
    vec4 extraMeta;      // textHeight, pivotOffsetX, pivotOffsetY, packed blend+material (uint bits)
    vec4 effects1;       // outlineColor, glowColor, shadowColor, shadowOffset (packed)
    vec4 effects2;       // outlineWidth, glowRadius, shadowBlur, spare
};

// Per-glyph data
struct GlyphData {
    vec4 localPosUV;     // localX, localY, uvX, uvY
    vec4 uvSizeWH;       // uvW, uvH, glyphW, glyphH
};

// Visible glyph index pair
struct VisibleGlyph {
    uint headerIndex;
    uint glyphIndex;
};

// FLAG_UNLIT and the screen-space flag constants come from
// render_common.glsl, along with the pass uniforms and filters.
const uint FLAG_MSDF = 0x10u;  // MSDF/SDF font rendering

layout(std430) readonly buffer TextHeaderBuffer {
    TextHeader headers[];
};

layout(std430) readonly buffer GlyphDataBuffer {
    GlyphData glyphs[];
};

layout(std430) readonly buffer VisibleGlyphBuffer {
    VisibleGlyph visibleGlyphs[];
};

uniform int ShadowPass;   // 0 = normal (fill+outline+glow), 1 = shadow pass
uniform ArrayImage SDFAtlas;
uniform float PxRange;

varying vec4 vColor;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying vec3 vTexCoord;  // xy = UV, z = font layer
varying float vFlags;
varying vec4 vEffects1;  // packed colors + shadow offset
varying vec4 vEffects2;  // scalars (outlineWidth, glowRadius, shadowBlur, spare)
varying vec2 vQuadPos;   // 0-1 position within glyph quad (for edge fading)
varying vec4 vUVBounds;  // atlas cell bounds: minU, minV, maxU, maxV (for texel clamping)

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_UNIT[love_VertexID];

    int instanceID = love_InstanceID;

    // Fetch visible glyph indices
    VisibleGlyph vg = visibleGlyphs[instanceID];

    // Fetch header and glyph data
    TextHeader h = headers[vg.headerIndex];
    GlyphData g = glyphs[vg.glyphIndex];

    // Extract header data
    vec2 entityPos = h.posLayer.xy;  // Pre-computed base position (after pivot offset)
    float zIndex = h.posLayer.z;
    float layer = h.posLayer.w;

    // Layer range filtering for multi-pass effects
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout in
    // extraMeta.w, stored as uint bits).
    uint packed = floatBitsToUint(h.extraMeta.w);
    if (blendPassFiltered(packed) || materialPassFiltered(packed)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    float rotation = h.rotScaleFlags.x;
    float scaleX = h.rotScaleFlags.y;
    float scaleY = h.rotScaleFlags.z;
    float flags = h.rotScaleFlags.w;
    uint flagBits = uint(flags);

    // Compute cos/sin from rotation (moved from CPU to GPU)
    float cosRot = cos(rotation);
    float sinRot = sin(rotation);

    // Determine screen-space properties from layer configuration
    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    vec4 color = h.color;
    vec4 clipBounds = h.clipBounds;
    float fontLayer = h.fontMeta.x;

    // Extract glyph data
    vec2 localPos = g.localPosUV.xy;
    vec2 uvOrigin = g.localPosUV.zw;
    vec2 uvSize = g.uvSizeWH.xy;
    vec2 glyphSize = g.uvSizeWH.zw;

    // Extract text dimensions and pivot offset
    float textWidth = h.fontMeta.w;
    float textHeight = h.extraMeta.x;
    float pivotOffsetX = h.extraMeta.y;
    float pivotOffsetY = h.extraMeta.z;

    // Glyph positions have center pivot (0.5, 0.5) baked in.
    // Adjust to actual pivot by adding back center offset and subtracting actual offset.
    vec2 pivotAdjust = vec2(textWidth * 0.5 - pivotOffsetX, textHeight * 0.5 - pivotOffsetY);
    localPos += pivotAdjust;

    // Apply entity scale to glyph
    vec2 scaledLocalPos = localPos * vec2(scaleX, scaleY);
    vec2 scaledGlyphSize = glyphSize * vec2(scaleX, scaleY);

    // Shadow pass: skip non-MSDF or entities without shadow, shift position
    if (ShadowPass != 0) {
        if ((flagBits & FLAG_MSDF) == 0u) return vec4(2.0, 2.0, 2.0, 1.0);
        vec2 shdOff = unpackHalf2x16(floatBitsToUint(h.effects1.w));
        float shdB = h.effects2.z;
        if (shdOff == vec2(0.0) && shdB <= 0.0) return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Glyph quad vertex in local space (no expansion; SDF padding in the atlas
    // provides room for outline/glow, shadow uses a separate shifted pass)
    vec2 local = quadPos * scaledGlyphSize;

    // Position relative to entity
    vec2 glyphPos = scaledLocalPos + local;

    // Rotate around entity origin
    vec2 rotated = vec2(
        glyphPos.x * cosRot - glyphPos.y * sinRot,
        glyphPos.x * sinRot + glyphPos.y * cosRot
    );

    // Final world position
    vec2 worldPos = entityPos + rotated;

    // Shadow pass: shift by shadow offset in world space (after rotation)
    if (ShadowPass != 0) {
        vec2 shdOff = unpackHalf2x16(floatBitsToUint(h.effects1.w));
        worldPos += shdOff;
    }

    // Texture coordinates (within atlas glyph region, includes SDF padding)
    vTexCoord = vec3(uvOrigin + quadPos * uvSize, fontLayer);
    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    // Compute depth for z-ordering using entity bottom Y
    // entityPos is at the pivot point, bottom is (textHeight - pivotOffsetY) below
    float bottomY = entityPos.y + (textHeight - pivotOffsetY) * scaleY;
    float depth = computeDepth(layer, zIndex, entityPos.x, bottomY, vg.headerIndex);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    // Shadow pass renders behind the fill pass
    float depthBias = (ShadowPass != 0) ? 1e-6 : 0.0;
    result.z = (depth + depthBias) * result.w;

    // OR in UNLIT flag if layer is in unlitMask
    float outFlags = flags;
    if (isUnlitLayer(layer)) {
        outFlags = float(uint(outFlags) | 1u);  // FLAG_UNLIT = 0x1
    }

    vColor = color;
    vWorldPos = worldPos;
    vClipBounds = clipBounds;
    vFlags = outFlags;
    vEffects1 = h.effects1;
    vEffects2 = h.effects2;
    vQuadPos = quadPos;
    vUVBounds = vec4(uvOrigin, uvOrigin + uvSize);

    return result;
}
#endif

#ifdef PIXEL
uniform ArrayImage MainTex;

// MSDF median-of-three
float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

// Sample MSDF with manual bilinear interpolation of the median.
// Standard hardware bilinear filtering interpolates R, G, B independently,
// then median() is taken on the mixed values. This produces artifacts at
// diagonal sampling angles where channel ordering flips between texels.
// Instead, compute median at each texel corner, then interpolate the result.
// uvBounds (minU, minV, maxU, maxV) clamps texelFetch to the glyph's atlas
// cell, preventing bleed from adjacent packed glyphs.
float sampleMSDFMedian(ArrayImage atlas, vec3 texCoord, vec2 atlasSize, vec4 uvBounds) {
    vec2 pos = texCoord.xy * atlasSize - 0.5;
    ivec2 ipos = ivec2(floor(pos));
    vec2 f = fract(pos);
    int layer = int(texCoord.z);

    // Clamp texel coordinates to stay within this glyph's atlas cell
    ivec2 cellMin = ivec2(floor(uvBounds.xy * atlasSize));
    ivec2 cellMax = ivec2(ceil(uvBounds.zw * atlasSize)) - 1;
    ivec2 p00 = clamp(ipos,              cellMin, cellMax);
    ivec2 p10 = clamp(ipos + ivec2(1,0), cellMin, cellMax);
    ivec2 p01 = clamp(ipos + ivec2(0,1), cellMin, cellMax);
    ivec2 p11 = clamp(ipos + ivec2(1,1), cellMin, cellMax);

    vec3 s00 = texelFetch(atlas, ivec3(p00, layer), 0).rgb;
    vec3 s10 = texelFetch(atlas, ivec3(p10, layer), 0).rgb;
    vec3 s01 = texelFetch(atlas, ivec3(p01, layer), 0).rgb;
    vec3 s11 = texelFetch(atlas, ivec3(p11, layer), 0).rgb;

    float d00 = median(s00.r, s00.g, s00.b);
    float d10 = median(s10.r, s10.g, s10.b);
    float d01 = median(s01.r, s01.g, s01.b);
    float d11 = median(s11.r, s11.g, s11.b);

    return mix(mix(d00, d10, f.x), mix(d01, d11, f.x), f.y);
}


void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    uint flags = uint(vFlags);
    bool isMSDF = (flags & FLAG_MSDF) != 0u;
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;
    float sdfDist = 0.0;
    vec4 finalColor;

    if (isMSDF) {
        // Screen-space pixel range for anti-aliasing
        vec2 atlasSize = vec2(textureSize(SDFAtlas, 0).xy);
        float texelsPerPx = length(fwidth(vTexCoord.xy) * atlasSize);
        float screenPxRange = max(PxRange / texelsPerPx, 1.0);

        // Sample SDF within the glyph's atlas region (includes PxRange/2 padding)
        float sd = sampleMSDFMedian(SDFAtlas, vec3(vTexCoord.xy, vTexCoord.z), atlasSize, vUVBounds);

        sdfDist = screenPxRange * (sd - 0.5);
        float fillAlpha = clamp(sdfDist + 0.5, 0.0, 1.0);

        // Quad-edge fade: smoothly attenuate outline/glow near quad boundaries
        // to prevent hard edges where adjacent glyph quads have gaps.
        // UV clamping in sampleMSDFMedian prevents atlas bleed; this handles
        // the remaining case where the glyph shape is close to the cell edge.
        float edgeDist = min(min(vQuadPos.x, 1.0 - vQuadPos.x), min(vQuadPos.y, 1.0 - vQuadPos.y));
        float edgeFade = smoothstep(0.0, 0.04, edgeDist);

        if (ShadowPass != 0) {
            // Shadow pass: render the fill shape with shadow color and blur.
            // The vertex shader already shifted this glyph by shadowOffset,
            // so the fill SDF here IS the shadow silhouette at the correct offset.
            vec4 shadowColor = unpackUnorm4x8(floatBitsToUint(vEffects1.z));
            float shadowBlur = vEffects2.z;
            float blur = max(shadowBlur, 0.05) * screenPxRange;
            float shadowAlpha = smoothstep(-blur, blur * 0.5, sdfDist);
            finalColor = vec4(shadowColor.rgb, shadowColor.a * shadowAlpha);
        } else {
            // Normal pass: glow + outline + fill (no shadow; handled by shadow pass)
            float outlineWidth = vEffects2.x;
            float glowRadius   = vEffects2.y;

            bool hasEffects = (outlineWidth > 0.0 || glowRadius > 0.0);

            if (hasEffects) {
                vec4 result = vec4(0.0);

                // 1. Glow (fills available SDF padding around glyph)
                if (glowRadius > 0.0) {
                    vec4 glowColor = unpackUnorm4x8(floatBitsToUint(vEffects1.y));
                    float availableRange = screenPxRange * 0.4;
                    float glowDist = clamp(-sdfDist, 0.0, availableRange);
                    float t = glowDist / availableRange;
                    float glowAlpha = (1.0 - t) * (1.0 - t) * min(glowRadius, 1.0) * edgeFade;
                    result = mix(result, vec4(glowColor.rgb, glowColor.a), glowAlpha * glowColor.a);
                }

                // 2. Outline (outer edge to inner edge)
                if (outlineWidth > 0.0) {
                    vec4 outlineColor = unpackUnorm4x8(floatBitsToUint(vEffects1.x));
                    float outerDist = sdfDist + outlineWidth * screenPxRange;
                    float outerAlpha = clamp(outerDist + 0.5, 0.0, 1.0) * edgeFade;
                    result = mix(result, vec4(outlineColor.rgb, outlineColor.a), outerAlpha * outlineColor.a);
                }

                // 3. Fill (no edge fade - fill is well within the glyph quad)
                result = mix(result, vColor, fillAlpha * vColor.a);
                finalColor = result;
            } else {
                // No effects: simple MSDF fill
                finalColor = vec4(vColor.rgb, vColor.a * fillAlpha);
            }
        }
    } else {
        // Bitmap text (unchanged)
        vec4 texColor = Texel(MainTex, vTexCoord);
        finalColor = texColor * vColor;
    }

    // Alpha test
    if (finalColor.a < 0.01) discard;

    // -- MATERIAL_BEGIN --
    // G-Buffer outputs
    love_Canvases[0] = finalColor;                       // Albedo
    love_Canvases[1] = vec4(0.5, 0.5, 1.0, litMarker);   // Normal (flat up) + unlit marker
    love_Canvases[2] = DEFAULT_ORM;
    love_Canvases[3] = vec4(0.0);                        // No emission for text
    // -- MATERIAL_END --
}
#endif
