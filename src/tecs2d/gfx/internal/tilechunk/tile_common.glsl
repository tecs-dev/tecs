// Shared TileChunk data structure and helpers
// Used by tilechunk render and shadow mask shaders

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

// Helper function to get tile ID group from separate fields
// Uses switch statement to access the correct field by index
uvec4 getTileGroup(TileChunkData chunk, int idx) {
    switch (idx) {
        case 0:  return chunk.t0;  case 1:  return chunk.t1;  case 2:  return chunk.t2;  case 3:  return chunk.t3;
        case 4:  return chunk.t4;  case 5:  return chunk.t5;  case 6:  return chunk.t6;  case 7:  return chunk.t7;
        case 8:  return chunk.t8;  case 9:  return chunk.t9;  case 10: return chunk.t10; case 11: return chunk.t11;
        case 12: return chunk.t12; case 13: return chunk.t13; case 14: return chunk.t14; case 15: return chunk.t15;
        case 16: return chunk.t16; case 17: return chunk.t17; case 18: return chunk.t18; case 19: return chunk.t19;
        case 20: return chunk.t20; case 21: return chunk.t21; case 22: return chunk.t22; case 23: return chunk.t23;
        case 24: return chunk.t24; case 25: return chunk.t25; case 26: return chunk.t26; case 27: return chunk.t27;
        case 28: return chunk.t28; case 29: return chunk.t29; case 30: return chunk.t30; case 31: return chunk.t31;
        case 32: return chunk.t32; case 33: return chunk.t33; case 34: return chunk.t34; case 35: return chunk.t35;
        case 36: return chunk.t36; case 37: return chunk.t37; case 38: return chunk.t38; case 39: return chunk.t39;
        case 40: return chunk.t40; case 41: return chunk.t41; case 42: return chunk.t42; case 43: return chunk.t43;
        case 44: return chunk.t44; case 45: return chunk.t45; case 46: return chunk.t46; case 47: return chunk.t47;
        case 48: return chunk.t48; case 49: return chunk.t49; case 50: return chunk.t50; case 51: return chunk.t51;
        case 52: return chunk.t52; case 53: return chunk.t53; case 54: return chunk.t54; case 55: return chunk.t55;
        case 56: return chunk.t56; case 57: return chunk.t57; case 58: return chunk.t58; case 59: return chunk.t59;
        case 60: return chunk.t60; case 61: return chunk.t61; case 62: return chunk.t62; default: return chunk.t63;
    }
}
