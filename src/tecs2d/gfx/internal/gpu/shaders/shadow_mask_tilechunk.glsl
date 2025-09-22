#pragma language glsl4

// TileChunk shadow mask shader
// Reads from shadow-only buffer populated by tilechunk cull shader's dual-write.
// Renders tile silhouettes to shadow mask, looking up per-tile occluder heights.

// TileChunkData struct and getTileGroup() are provided by tile_common.glsl

layout(std430) readonly buffer TileChunkShadowOutput {
    TileChunkData chunks[];
};

uniform mat4 ShadowViewProj;
uniform vec2 TilesetSize;     // Tileset texture dimensions in pixels
uniform float AlphaThreshold; // Default 0.5

varying vec3 vTexCoord;       // .xy = UV, .z = texture array layer
varying float vTileId;        // For discarding empty tiles (id == 0)
varying float vOccluderHeight;

#ifdef VERTEX
// Quad vertex positions (2 triangles, CCW winding)
const vec2 QUAD_POSITIONS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),  // First triangle
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)   // Second triangle
);

// Height lookup texture: row = tileset layer, col = local tile ID
// Value = normalized height 0-1 (r16f format)
uniform sampler2D HeightLookup;
uniform vec2 HeightLookupSize;  // width, height of height lookup texture

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 quadPos = QUAD_POSITIONS[love_VertexID];

    // Decode chunk and tile index (same as tilechunk.glsl)
    int instanceID = love_InstanceID;
    int chunkIndex = instanceID / 256;
    int localTile = instanceID % 256;

    TileChunkData chunk = chunks[chunkIndex];

    // Get tile ID
    int uvec4Index = localTile / 4;
    int componentIndex = localTile % 4;
    uvec4 tileGroup = getTileGroup(chunk, uvec4Index);
    uint tileId = tileGroup[componentIndex];

    vTileId = float(tileId);

    // If tile is empty, move off-screen
    if (tileId == 0u) {
        vOccluderHeight = 0.0;
        return vec4(-10000.0, -10000.0, 0.0, 1.0);
    }

    // Get texture layer index for height lookup
    float textureIndex = chunk.layerInfo.w;

    // Look up occluder height from 2D texture
    // Row = textureIndex (tileset layer), Col = local tile ID (tileId - 1, since tile IDs are 1-based)
    uint localId = tileId - 1u;
    vec2 lookupCoord = vec2(
        (float(localId) + 0.5) / HeightLookupSize.x,
        (textureIndex + 0.5) / HeightLookupSize.y
    );
    float height = texture(HeightLookup, lookupCoord).r;  // Already normalized 0-1

    // If this tile has no occluder height, skip it
    if (height < 0.001) {
        vOccluderHeight = 0.0;
        return vec4(-10000.0, -10000.0, 0.0, 1.0);
    }

    vOccluderHeight = height;

    // Decode local position within chunk (16x16 grid)
    int tileX = localTile % 16;
    int tileY = localTile / 16;

    float tw = chunk.posSize.z;
    float th = chunk.posSize.w;
    float columns = chunk.layerInfo.z;

    // Calculate world position of this tile
    vec2 chunkPos = chunk.posSize.xy;
    vec2 tileOffset = vec2(float(tileX) * tw, float(tileY) * th);
    vec2 worldPos = chunkPos + tileOffset + quadPos * vec2(tw, th);

    // Calculate UV coordinates from tile ID
    uint atlasId = tileId - 1u;
    float col = mod(float(atlasId), columns);
    float row = floor(float(atlasId) / columns);

    vec2 uvTileSize = vec2(tw, th) / TilesetSize;
    vec2 uvBase = vec2(col * tw, row * th) / TilesetSize;
    vec2 uv = uvBase + quadPos * uvTileSize;

    vTexCoord = vec3(uv, textureIndex);

    vec2 screenPos = (ShadowViewProj * vec4(worldPos, 0.0, 1.0)).xy;

    return transform_projection * vec4(screenPos, 0.0, 1.0);
}
#endif

#ifdef PIXEL
uniform ArrayImage TileChunkMainTex;  // Tileset texture array

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    // Discard empty tiles
    if (vTileId < 0.5) {
        discard;
    }

    // Discard tiles with no occluder height
    if (vOccluderHeight < 0.001) {
        discard;
    }

    // Sample texture array for alpha test
    vec4 texColor = Texel(TileChunkMainTex, vTexCoord);

    // Alpha test - discard if below threshold
    if (texColor.a < AlphaThreshold) {
        discard;
    }

    // Encode occluder height in red channel (already normalized 0-1)
    float normalizedHeight = clamp(vOccluderHeight, 0.0, 1.0);

    // G=1 marks actual occluder pixels (distinguished from blur halo by lighting shader)
    return vec4(normalizedHeight, 1.0, 0.0, 1.0);
}
#endif
