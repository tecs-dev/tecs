#pragma language glsl4

layout(local_size_x = 256) in;

// Input: all tile chunks
// Note: tiles are separate fields (not array) to match Love2D buffer format validation
struct TileChunkIn {
    vec4 posSize;       // x, y (chunk world pos), tileWidth, tileHeight
    vec4 layerInfo;     // layer, z, columns, textureIndex
    vec4 color;         // r, g, b, a
    vec4 occluderInfo;  // occluderHeight, _pad, hasOccluders, _pad
    // 256 tile IDs as 64 uvec4s (separate fields for Love2D buffer format compatibility)
    uvec4 t0;  uvec4 t1;  uvec4 t2;  uvec4 t3;  uvec4 t4;  uvec4 t5;  uvec4 t6;  uvec4 t7;
    uvec4 t8;  uvec4 t9;  uvec4 t10; uvec4 t11; uvec4 t12; uvec4 t13; uvec4 t14; uvec4 t15;
    uvec4 t16; uvec4 t17; uvec4 t18; uvec4 t19; uvec4 t20; uvec4 t21; uvec4 t22; uvec4 t23;
    uvec4 t24; uvec4 t25; uvec4 t26; uvec4 t27; uvec4 t28; uvec4 t29; uvec4 t30; uvec4 t31;
    uvec4 t32; uvec4 t33; uvec4 t34; uvec4 t35; uvec4 t36; uvec4 t37; uvec4 t38; uvec4 t39;
    uvec4 t40; uvec4 t41; uvec4 t42; uvec4 t43; uvec4 t44; uvec4 t45; uvec4 t46; uvec4 t47;
    uvec4 t48; uvec4 t49; uvec4 t50; uvec4 t51; uvec4 t52; uvec4 t53; uvec4 t54; uvec4 t55;
    uvec4 t56; uvec4 t57; uvec4 t58; uvec4 t59; uvec4 t60; uvec4 t61; uvec4 t62; uvec4 t63;
};

layout(std430) readonly buffer TileChunkInput {
    TileChunkIn chunksIn[];
};

// Output: visible tile chunks (same structure, compacted)
struct TileChunkOut {
    vec4 posSize;
    vec4 layerInfo;
    vec4 color;
    vec4 occluderInfo;
    uvec4 t0;  uvec4 t1;  uvec4 t2;  uvec4 t3;  uvec4 t4;  uvec4 t5;  uvec4 t6;  uvec4 t7;
    uvec4 t8;  uvec4 t9;  uvec4 t10; uvec4 t11; uvec4 t12; uvec4 t13; uvec4 t14; uvec4 t15;
    uvec4 t16; uvec4 t17; uvec4 t18; uvec4 t19; uvec4 t20; uvec4 t21; uvec4 t22; uvec4 t23;
    uvec4 t24; uvec4 t25; uvec4 t26; uvec4 t27; uvec4 t28; uvec4 t29; uvec4 t30; uvec4 t31;
    uvec4 t32; uvec4 t33; uvec4 t34; uvec4 t35; uvec4 t36; uvec4 t37; uvec4 t38; uvec4 t39;
    uvec4 t40; uvec4 t41; uvec4 t42; uvec4 t43; uvec4 t44; uvec4 t45; uvec4 t46; uvec4 t47;
    uvec4 t48; uvec4 t49; uvec4 t50; uvec4 t51; uvec4 t52; uvec4 t53; uvec4 t54; uvec4 t55;
    uvec4 t56; uvec4 t57; uvec4 t58; uvec4 t59; uvec4 t60; uvec4 t61; uvec4 t62; uvec4 t63;
};

layout(std430) writeonly buffer TileChunkOutput {
    TileChunkOut chunksOut[];
};

// Shadow output: chunks with occluding tiles (for shadow mask pass)
layout(std430) writeonly buffer TileChunkShadowOutput {
    TileChunkOut chunksShadowOut[];
};

layout(std430) buffer IndirectArgs {
    uint args[];  // vertexCount, instanceCount, firstVertex, firstInstance
};

// Shadow indirect args (separate buffer, same format)
layout(std430) buffer ShadowIndirectArgs {
    uint shadowArgs[];  // vertexCount, instanceCount, firstVertex, firstInstance
};

uniform vec4 CameraViewport;  // left, top, right, bottom in world space
uniform vec2 CameraPos;       // Camera position (for parallax calculation)
uniform mat4 ParallaxX;       // Parallax X factors for layers 1-16 (packed in mat4)
uniform mat4 ParallaxY;       // Parallax Y factors for layers 1-16 (packed in mat4)
uniform uint TotalChunks;
uniform uint CameraLayerMask;
uniform float ShadowMargin;   // Extra margin for occluder cull expansion

// Get parallax factors for a layer (mat4 stores 16 values: col*4+row = layer-1)
vec2 getParallaxFactor(float layer) {
    int idx = int(layer) - 1;
    int col = idx / 4;
    int row = idx % 4;
    return vec2(ParallaxX[col][row], ParallaxY[col][row]);
}

// Macro to copy all 64 tile uvec4 fields from input chunk to an output buffer slot.
// Used for both main output and shadow output (only the destination buffer differs).
#define COPY_TILE_DATA(DST, outIdx, chunk) \
    DST[outIdx].t0 = chunk.t0;   DST[outIdx].t1 = chunk.t1;   \
    DST[outIdx].t2 = chunk.t2;   DST[outIdx].t3 = chunk.t3;   \
    DST[outIdx].t4 = chunk.t4;   DST[outIdx].t5 = chunk.t5;   \
    DST[outIdx].t6 = chunk.t6;   DST[outIdx].t7 = chunk.t7;   \
    DST[outIdx].t8 = chunk.t8;   DST[outIdx].t9 = chunk.t9;   \
    DST[outIdx].t10 = chunk.t10; DST[outIdx].t11 = chunk.t11; \
    DST[outIdx].t12 = chunk.t12; DST[outIdx].t13 = chunk.t13; \
    DST[outIdx].t14 = chunk.t14; DST[outIdx].t15 = chunk.t15; \
    DST[outIdx].t16 = chunk.t16; DST[outIdx].t17 = chunk.t17; \
    DST[outIdx].t18 = chunk.t18; DST[outIdx].t19 = chunk.t19; \
    DST[outIdx].t20 = chunk.t20; DST[outIdx].t21 = chunk.t21; \
    DST[outIdx].t22 = chunk.t22; DST[outIdx].t23 = chunk.t23; \
    DST[outIdx].t24 = chunk.t24; DST[outIdx].t25 = chunk.t25; \
    DST[outIdx].t26 = chunk.t26; DST[outIdx].t27 = chunk.t27; \
    DST[outIdx].t28 = chunk.t28; DST[outIdx].t29 = chunk.t29; \
    DST[outIdx].t30 = chunk.t30; DST[outIdx].t31 = chunk.t31; \
    DST[outIdx].t32 = chunk.t32; DST[outIdx].t33 = chunk.t33; \
    DST[outIdx].t34 = chunk.t34; DST[outIdx].t35 = chunk.t35; \
    DST[outIdx].t36 = chunk.t36; DST[outIdx].t37 = chunk.t37; \
    DST[outIdx].t38 = chunk.t38; DST[outIdx].t39 = chunk.t39; \
    DST[outIdx].t40 = chunk.t40; DST[outIdx].t41 = chunk.t41; \
    DST[outIdx].t42 = chunk.t42; DST[outIdx].t43 = chunk.t43; \
    DST[outIdx].t44 = chunk.t44; DST[outIdx].t45 = chunk.t45; \
    DST[outIdx].t46 = chunk.t46; DST[outIdx].t47 = chunk.t47; \
    DST[outIdx].t48 = chunk.t48; DST[outIdx].t49 = chunk.t49; \
    DST[outIdx].t50 = chunk.t50; DST[outIdx].t51 = chunk.t51; \
    DST[outIdx].t52 = chunk.t52; DST[outIdx].t53 = chunk.t53; \
    DST[outIdx].t54 = chunk.t54; DST[outIdx].t55 = chunk.t55; \
    DST[outIdx].t56 = chunk.t56; DST[outIdx].t57 = chunk.t57; \
    DST[outIdx].t58 = chunk.t58; DST[outIdx].t59 = chunk.t59; \
    DST[outIdx].t60 = chunk.t60; DST[outIdx].t61 = chunk.t61; \
    DST[outIdx].t62 = chunk.t62; DST[outIdx].t63 = chunk.t63;

void computemain() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= TotalChunks) return;

    TileChunkIn chunk = chunksIn[idx];

    // Calculate chunk bounding box in world space
    float x = chunk.posSize.x;
    float y = chunk.posSize.y;
    float tw = chunk.posSize.z;
    float th = chunk.posSize.w;

    // Chunk covers 16x16 tiles
    float chunkWidth = tw * 16.0;
    float chunkHeight = th * 16.0;

    float left = x;
    float top = y;
    float right = x + chunkWidth;
    float bottom = y + chunkHeight;

    // Expand culling bounds for chunks with occluding tiles
    bool hasOccluders = chunk.occluderInfo.z > 0.5;
    if (hasOccluders) {
        left -= ShadowMargin;
        top -= ShadowMargin;
        right += ShadowMargin;
        bottom += ShadowMargin;
    }

    // Check camera layer visibility
    float layer = chunk.layerInfo.x;
    uint layerIdx = uint(layer) - 1u;
    if (((CameraLayerMask >> layerIdx) & 1u) != 1u) return;
    vec2 parallax = getParallaxFactor(layer);
    float parallaxOffsetX = CameraPos.x * (1.0 - parallax.x);
    float parallaxOffsetY = CameraPos.y * (1.0 - parallax.y);
    float adjLeft = left + parallaxOffsetX;
    float adjRight = right + parallaxOffsetX;
    float adjTop = top + parallaxOffsetY;
    float adjBottom = bottom + parallaxOffsetY;

    // Frustum culling
    bool visible = (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                   (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);

    // Also skip chunks with zero tile dimensions (invalid/freed)
    visible = visible && (tw > 0.0) && (th > 0.0);

    if (visible) {
        // Get output slot via atomic add
        // We increment by 256 because each chunk = 256 tile instances
        uint outIdx = atomicAdd(args[1], 256u) / 256u;

        // Apply parallax offset to output position
        float outX = x + parallaxOffsetX;
        float outY = y + parallaxOffsetY;

        // Copy chunk data to output (with parallax-adjusted position)
        chunksOut[outIdx].posSize = vec4(outX, outY, tw, th);
        chunksOut[outIdx].layerInfo = chunk.layerInfo;
        chunksOut[outIdx].color = chunk.color;
        chunksOut[outIdx].occluderInfo = chunk.occluderInfo;

        // Copy tile data
        COPY_TILE_DATA(chunksOut, outIdx, chunk)

        // Check if chunk has any occluding tiles - if so, also write to shadow buffer
        bool hasOccluders = chunk.occluderInfo.z > 0.5;
        if (hasOccluders) {
            // Get shadow output slot
            uint shadowOutIdx = atomicAdd(shadowArgs[1], 256u) / 256u;

            // Copy to shadow output
            chunksShadowOut[shadowOutIdx].posSize = vec4(outX, outY, tw, th);
            chunksShadowOut[shadowOutIdx].layerInfo = chunk.layerInfo;
            chunksShadowOut[shadowOutIdx].color = chunk.color;
            chunksShadowOut[shadowOutIdx].occluderInfo = chunk.occluderInfo;

            // Copy tile data to shadow output
            COPY_TILE_DATA(chunksShadowOut, shadowOutIdx, chunk)
        }
    }
}
