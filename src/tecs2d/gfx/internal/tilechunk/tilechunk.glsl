#pragma language glsl4

// TileChunkData struct and getTileGroup() are provided by tile_common.glsl

layout(std430) readonly buffer TileChunkOutput {
    TileChunkData chunks[];
};

uniform vec2 TilesetSize;     // Tileset texture dimensions in pixels

// Per-tile varying outputs
varying vec4 vColor;
varying vec3 vTexCoord;       // .xy = UV, .z = texture array layer
varying vec2 vWorldPos;
varying float vTileId;        // For discarding empty tiles (id == 0)
varying float vLitMarker;     // 1.0 = receives lighting, 0.0 = unlit

#ifdef VERTEX
// Quad vertex positions (2 triangles, CCW winding)
const vec2 QUAD_POSITIONS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),  // First triangle
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)   // Second triangle
);

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS[love_VertexID];

    // love_InstanceID encodes both chunk index and local tile index
    // We use gl_BaseInstance (chunk index) + local tile (0-255)
    // But Love2D doesn't expose gl_BaseInstance, so we pack it differently:
    // The dispatch will be: drawFromShaderIndirect with instanceCount = numVisibleChunks * 256
    // So: chunkIndex = love_InstanceID / 256, localTile = love_InstanceID % 256
    int instanceID = love_InstanceID;
    int chunkIndex = instanceID / 256;
    int localTile = instanceID % 256;

    TileChunkData chunk = chunks[chunkIndex];

    // Layer range filtering for multi-pass effects
    if (chunk.layerInfo.x < LayerRange.x || chunk.layerInfo.x > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Get tile ID from packed uvec4 fields
    // Each uvec4 holds 4 tile IDs (as 4 uints)
    int uvec4Index = localTile / 4;
    int componentIndex = localTile % 4;
    uvec4 tileGroup = getTileGroup(chunk, uvec4Index);
    uint tileId = tileGroup[componentIndex];

    // Pass tile ID to fragment shader for discard check
    vTileId = float(tileId);

    // If tile is empty (id == 0), move it off-screen
    // (we'll also discard in fragment shader, but this saves fragment work)
    if (tileId == 0u) {
        return vec4(-10000.0, -10000.0, 0.0, 1.0);
    }

    // Decode local position within chunk (16x16 grid)
    int tileX = localTile % 16;
    int tileY = localTile / 16;

    float tw = chunk.posSize.z;  // tile width
    float th = chunk.posSize.w;  // tile height
    float columns = chunk.layerInfo.z;  // tileset columns

    // Calculate world position of this tile
    vec2 chunkPos = chunk.posSize.xy;
    vec2 tileOffset = vec2(float(tileX) * tw, float(tileY) * th);

    // Unit quad (0,0 to 1,1) scaled to tile size
    vec2 localPos = quadPos;
    vec2 worldPos = chunkPos + tileOffset + localPos * vec2(tw, th);

    // Calculate UV coordinates from tile ID
    // Tile IDs are 1-based in Tiled, so subtract 1 for 0-based atlas lookup
    uint atlasId = tileId - 1u;
    float col = mod(float(atlasId), columns);
    float row = floor(float(atlasId) / columns);

    // UV rect for this tile
    vec2 uvTileSize = vec2(tw, th) / TilesetSize;
    vec2 uvBase = vec2(col * tw, row * th) / TilesetSize;
    vec2 uv = uvBase + localPos * uvTileSize;

    // Pass texture array layer from chunk data
    float textureLayer = chunk.layerInfo.w;
    vTexCoord = vec3(uv, textureLayer);

    // World to screen transform
    vec2 screenPos = (worldPos - CameraPos) * CameraZoom + ScreenHalf + CameraSubPixel;

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);

    // Compute depth for z-ordering (shared function from depth_common.glsl)
    float layer = chunk.layerInfo.x;
    float z = chunk.layerInfo.y;
    float bottomY = worldPos.y + chunk.posSize.w;  // Bottom of tile for Y-sorting
    float depth = computeDepth(layer, z, worldPos.x, bottomY, 0u);
    result.z = depth * result.w;

    vColor = chunk.color;
    vWorldPos = worldPos;
    // Set lit marker based on layer (0.0 = unlit, 1.0 = lit)
    vLitMarker = isUnlitLayer(layer) ? 0.0 : 1.0;
    return result;
}
#endif

#ifdef PIXEL
uniform ArrayImage MainTex;      // Tileset texture array (albedo)
uniform ArrayImage NormalTex;    // Normal map array
uniform ArrayImage EmissionTex;  // Emission map array
uniform ArrayImage ORMTex;       // ORM map array (R=AO, G=roughness, B=metallic)

void effect() {
    // Discard empty tiles
    if (vTileId < 0.5) {
        discard;
    }

    // Sample from texture arrays using layer index
    vec4 texColor = Texel(MainTex, vTexCoord);
    vec4 finalColor = texColor * vColor;

    // Alpha test for tile transparency
    if (finalColor.a < 0.01) {
        discard;
    }

    // Sample normal map (use flat normal if alpha is 0)
    vec4 normalSample = Texel(NormalTex, vTexCoord);
    vec3 normal = normalSample.a > 0.01 ? normalSample.rgb : vec3(0.5, 0.5, 1.0);

    // Sample emission map (output separately, added after lighting)
    vec4 emission = Texel(EmissionTex, vTexCoord);

    // Sample ORM map: R = AO, G = roughness, B = metallic
    vec4 orm = Texel(ORMTex, vTexCoord);

    // G-Buffer outputs
    love_Canvases[0] = finalColor;                   // Albedo
    love_Canvases[1] = vec4(normal, vLitMarker);     // Normal + unlit marker
    love_Canvases[2] = orm;                          // ORM (AO, roughness, metallic)
    love_Canvases[3] = emission;                     // Emission (added after lighting)
    love_Canvases[4] = vec4(floor(gl_FragCoord.z * 255.0) / 255.0, fract(gl_FragCoord.z * 255.0), 0.0, 1.0); // Depth (16-bit RG)
}
#endif
