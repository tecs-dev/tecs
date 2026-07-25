#pragma language glsl4

layout(local_size_x = 256) in;

// Input: all tile chunks
// Note: tiles are separate fields (not array) to match Love2D buffer format validation
struct TileChunkIn {
    vec4 posSize;       // x, y (chunk world pos), tileWidth, tileHeight
    vec4 layerInfo;     // layer, z, columns, textureIndex
    vec4 color;         // r, g, b, a
    vec4 occluderInfo;  // occluderHeight, atlasSpacing, hasOccluders, atlasMargin
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

// Output: compact visible-chunk records. Tile data stays in the input
// buffer; render passes follow srcIndex back to it instead of copying
// the 1KB tile payload per visible chunk.
struct TileChunkVis {
    vec4 posSize;       // parallax-adjusted x, y, tileWidth, tileHeight
    uvec4 srcIndex;     // x = row in TileChunkInput; yzw unused
};

layout(std430) writeonly buffer TileChunkOutput {
    TileChunkVis chunksOut[];
};

// Shadow output: chunks with occluding tiles (for shadow mask pass)
layout(std430) writeonly buffer TileChunkShadowOutput {
    TileChunkVis chunksShadowOut[];
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

void computemain() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= TotalChunks) return;

    // Only the header lanes are needed for culling; tile data stays in
    // the input buffer.
    vec4 posSize = chunksIn[idx].posSize;
    vec4 layerInfo = chunksIn[idx].layerInfo;
    vec4 occluderInfo = chunksIn[idx].occluderInfo;

    // Calculate chunk bounding box in world space
    float x = posSize.x;
    float y = posSize.y;
    float tw = posSize.z;
    float th = posSize.w;

    // Chunk covers 16x16 tiles
    float chunkWidth = tw * 16.0;
    float chunkHeight = th * 16.0;

    float left = x;
    float top = y;
    float right = x + chunkWidth;
    float bottom = y + chunkHeight;

    // Expand culling bounds for chunks with occluding tiles
    bool hasOccluders = occluderInfo.z > 0.5;
    if (hasOccluders) {
        left -= ShadowMargin;
        top -= ShadowMargin;
        right += ShadowMargin;
        bottom += ShadowMargin;
    }

    // Check camera layer visibility
    float layer = layerInfo.x;
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

        chunksOut[outIdx].posSize = vec4(outX, outY, tw, th);
        chunksOut[outIdx].srcIndex = uvec4(idx, 0u, 0u, 0u);

        // Chunks with occluding tiles also compact into the shadow list
        if (hasOccluders) {
            uint shadowOutIdx = atomicAdd(shadowArgs[1], 256u) / 256u;
            chunksShadowOut[shadowOutIdx].posSize = vec4(outX, outY, tw, th);
            chunksShadowOut[shadowOutIdx].srcIndex = uvec4(idx, 0u, 0u, 0u);
        }
    }
}
