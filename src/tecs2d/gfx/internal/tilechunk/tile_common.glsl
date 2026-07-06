// Shared TileChunk data structures and helpers
// Used by the tilechunk render and shadow mask shaders.

// Each chunk represents a 16x16 grid of tiles
// Note: tiles are separate fields (not array) to match Love2D buffer format validation
struct TileChunkData {
    vec4 posSize;       // x, y (chunk world pos), tileWidth, tileHeight
    vec4 layerInfo;     // layer, z, columns (tileset columns), textureIndex (for texture array)
    vec4 color;         // r, g, b, a (tint)
    vec4 occluderInfo;  // occluderHeight, _pad, hasOccluders, _pad (for shadow casting)
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

// All-chunks input buffer, written by the CPU sync. The cull pass
// compacts visible chunks into TileChunkVis records that reference
// rows in this buffer, so render passes bind it too.
layout(std430) readonly buffer TileChunkInput {
    TileChunkData chunksIn[];
};

// Compact visible-chunk record written by the cull pass. posSize is
// parallax-adjusted; every other chunk field (layerInfo, color, tiles)
// is read from TileChunkInput via srcIndex.x. Must match
// TILECHUNK_VIS_FORMAT in gpu/types.tl.
struct TileChunkVis {
    vec4 posSize;       // parallax-adjusted x, y, tileWidth, tileHeight
    uvec4 srcIndex;     // x = row in TileChunkInput; yzw unused
};

// Fetch a group of 4 tile IDs from the input buffer by chunk row.
// The switch stands in for array indexing because Love2D buffer format
// validation requires the 64 uvec4s to be separate struct fields.
uvec4 getTileGroup(uint chunkIdx, int idx) {
    switch (idx) {
        case 0:  return chunksIn[chunkIdx].t0;  case 1:  return chunksIn[chunkIdx].t1;  case 2:  return chunksIn[chunkIdx].t2;  case 3:  return chunksIn[chunkIdx].t3;
        case 4:  return chunksIn[chunkIdx].t4;  case 5:  return chunksIn[chunkIdx].t5;  case 6:  return chunksIn[chunkIdx].t6;  case 7:  return chunksIn[chunkIdx].t7;
        case 8:  return chunksIn[chunkIdx].t8;  case 9:  return chunksIn[chunkIdx].t9;  case 10: return chunksIn[chunkIdx].t10; case 11: return chunksIn[chunkIdx].t11;
        case 12: return chunksIn[chunkIdx].t12; case 13: return chunksIn[chunkIdx].t13; case 14: return chunksIn[chunkIdx].t14; case 15: return chunksIn[chunkIdx].t15;
        case 16: return chunksIn[chunkIdx].t16; case 17: return chunksIn[chunkIdx].t17; case 18: return chunksIn[chunkIdx].t18; case 19: return chunksIn[chunkIdx].t19;
        case 20: return chunksIn[chunkIdx].t20; case 21: return chunksIn[chunkIdx].t21; case 22: return chunksIn[chunkIdx].t22; case 23: return chunksIn[chunkIdx].t23;
        case 24: return chunksIn[chunkIdx].t24; case 25: return chunksIn[chunkIdx].t25; case 26: return chunksIn[chunkIdx].t26; case 27: return chunksIn[chunkIdx].t27;
        case 28: return chunksIn[chunkIdx].t28; case 29: return chunksIn[chunkIdx].t29; case 30: return chunksIn[chunkIdx].t30; case 31: return chunksIn[chunkIdx].t31;
        case 32: return chunksIn[chunkIdx].t32; case 33: return chunksIn[chunkIdx].t33; case 34: return chunksIn[chunkIdx].t34; case 35: return chunksIn[chunkIdx].t35;
        case 36: return chunksIn[chunkIdx].t36; case 37: return chunksIn[chunkIdx].t37; case 38: return chunksIn[chunkIdx].t38; case 39: return chunksIn[chunkIdx].t39;
        case 40: return chunksIn[chunkIdx].t40; case 41: return chunksIn[chunkIdx].t41; case 42: return chunksIn[chunkIdx].t42; case 43: return chunksIn[chunkIdx].t43;
        case 44: return chunksIn[chunkIdx].t44; case 45: return chunksIn[chunkIdx].t45; case 46: return chunksIn[chunkIdx].t46; case 47: return chunksIn[chunkIdx].t47;
        case 48: return chunksIn[chunkIdx].t48; case 49: return chunksIn[chunkIdx].t49; case 50: return chunksIn[chunkIdx].t50; case 51: return chunksIn[chunkIdx].t51;
        case 52: return chunksIn[chunkIdx].t52; case 53: return chunksIn[chunkIdx].t53; case 54: return chunksIn[chunkIdx].t54; case 55: return chunksIn[chunkIdx].t55;
        case 56: return chunksIn[chunkIdx].t56; case 57: return chunksIn[chunkIdx].t57; case 58: return chunksIn[chunkIdx].t58; case 59: return chunksIn[chunkIdx].t59;
        case 60: return chunksIn[chunkIdx].t60; case 61: return chunksIn[chunkIdx].t61; case 62: return chunksIn[chunkIdx].t62; default: return chunksIn[chunkIdx].t63;
    }
}
