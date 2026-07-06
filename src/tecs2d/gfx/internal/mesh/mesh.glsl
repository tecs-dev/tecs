#pragma language glsl4

// Mesh instance data from cull shader output
struct MeshInstance {
    vec4 posLayer;         // x, y, z, layerFloat
    vec4 color;            // r, g, b, a
    vec4 scaleRotFlags;    // scaleX, scaleY, rotation, spare
    vec4 pivot;            // pivotX, pivotY, _pad, _pad
    vec4 clipBounds;       // minX, minY, maxX, maxY
    uvec4 flags;           // packed flags, depthBits, _pad, _pad
};

// Flag constants, pass uniforms, and pass-filter helpers come from
// render_common.glsl.

layout(std430) readonly buffer MeshOutput {
    MeshInstance instances[];
};

varying vec4 vColor;
varying vec2 vTexCoord;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying float vFlags;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    int instanceID = love_InstanceID;
    MeshInstance inst = instances[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = inst.posLayer.w;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout).
    uint flagBits = inst.flags.x;
    if (blendPassFiltered(flagBits) || materialPassFiltered(flagBits)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Extract transform data
    vec2 pos = inst.posLayer.xy;
    vec2 pivot = inst.pivot.xy;
    vec2 scale = inst.scaleRotFlags.xy;
    float rotation = inst.scaleRotFlags.z;

    // Check screen-space flags
    bool isScreenSpace = (flagBits & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (flagBits & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (flagBits & FLAG_VIRTUAL_COORDS) != 0u;

    // Transform vertex around pivot
    vec2 local = vertex_position.xy - pivot;
    vec2 scaled = local * scale;
    float c = cos(rotation);
    float s = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
    vec2 worldPos = pos + rotated;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    // Read pre-computed depth from cull shader
    float depth = uintBitsToFloat(inst.flags.y);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = depth * result.w;

    // Pass to fragment shader
    vColor = inst.color;
    vTexCoord = VertexTexCoord.xy;
    vWorldPos = worldPos;
    vClipBounds = inst.clipBounds;
    // Fragment only needs the low flag bits (FLAG_UNLIT); the full packed
    // value exceeds float's 24-bit exact integer range once materialId is set.
    vFlags = float(flagBits & 0xFFFFu);

    return result;
}
#endif

#ifdef PIXEL
uniform Image MainTex;

void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    // Sample texture if available (use Texel which works with Image type)
    vec4 texColor = Texel(MainTex, vTexCoord);
    vec4 finalColor = texColor * vColor * VaryingColor;

    // Alpha test
    if (finalColor.a < 0.01) {
        discard;
    }

    // Check unlit flag
    uint flags = uint(vFlags);
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;

    // G-buffer output
    love_Canvases[0] = finalColor;  // Albedo
    love_Canvases[1] = vec4(0.5, 0.5, 1.0, litMarker);  // Flat normal + unlit flag
    love_Canvases[2] = DEFAULT_ORM;
    love_Canvases[3] = vec4(0.0);  // No emission for meshes
}
#endif
